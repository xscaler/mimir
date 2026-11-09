// SPDX-License-Identifier: AGPL-3.0-only

package mimir

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"strings"
	"time"

	"github.com/go-kit/log"
	"github.com/go-kit/log/level"
	"github.com/grafana/dskit/runtimeconfig"
	"github.com/grafana/dskit/services"
	"github.com/grafana/dskit/user"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/xscaler/dskit/xstenant"
	"google.golang.org/grpc/metadata"

	"github.com/grafana/mimir/pkg/distributor"
	"github.com/grafana/mimir/pkg/mimirpb"
	"github.com/grafana/mimir/pkg/ruler"
	"github.com/grafana/mimir/pkg/storage/bucket"
	util_log "github.com/grafana/mimir/pkg/util/log"
	"github.com/grafana/mimir/pkg/util/validation"
)

const adminStoreEngine = "mimir"

// AdminStoreConfig configures reading per-tenant limits from the admin store
// that the xScaler control plane publishes to object storage.
type AdminStoreConfig struct {
	Enabled      bool          `yaml:"enabled" category:"experimental"`
	CacheDir     string        `yaml:"cache_dir" category:"experimental"`
	PollInterval time.Duration `yaml:"poll_interval" category:"experimental"`
	StartupWait  time.Duration `yaml:"startup_wait" category:"experimental"`
	EnforceState string        `yaml:"enforce_state" category:"experimental"`

	Bucket bucket.Config `yaml:",inline"`
}

// RegisterFlags registers the admin store flags.
func (c *AdminStoreConfig) RegisterFlags(f *flag.FlagSet) {
	f.BoolVar(&c.Enabled, "xscaler.admin-store.enabled", false, "Read per-tenant limits from the xScaler admin store in object storage. While enabled, per-tenant limits come only from the admin store and per-tenant overrides in the runtime configuration are ignored.")
	f.StringVar(&c.CacheDir, "xscaler.admin-store.cache-dir", "", "Directory where the last applied admin store generation is kept, so a restart can serve it while the bucket is unreachable. Empty disables the cache.")
	f.DurationVar(&c.PollInterval, "xscaler.admin-store.poll-interval", 5*time.Second, "How often the admin store manifest is polled.")
	f.DurationVar(&c.StartupWait, "xscaler.admin-store.startup-wait", 30*time.Second, "How long to wait for the first admin store snapshot at startup before continuing with default limits. Must be positive. The compactor module additionally waits, without a limit, until the first snapshot is applied before it starts. In a process that also runs the compactor (for example -target=all), /ready stays not ready until the first snapshot is applied, while the other modules keep serving.")
	f.StringVar(&c.EnforceState, "xscaler.admin-store.enforce-state", xstenant.EnforceOff.String(), "Deny the pushes of tenants that the admin store publishes as soft_locked (billing): remote write, OTLP and Influx get HTTP 429 with Retry-After 60, gRPC gets ResourceExhausted. Reads are never denied. Requires the admin store to be enabled. Supported values: off, shadow (never denies, counts the pushes it would deny), on.")
	c.Bucket.RegisterFlagsWithPrefix("xscaler.admin-store.", f)
}

// Validate validates the admin store configuration.
func (c *AdminStoreConfig) Validate() error {
	if !c.Enabled {
		return nil
	}
	if _, err := xstenant.ParseEnforceMode(c.EnforceState); err != nil && c.EnforceState != "" {
		return fmt.Errorf("xscaler.admin-store.enforce-state: %w", err)
	}
	if c.PollInterval <= 0 {
		return errors.New("xscaler.admin-store.poll-interval must be positive")
	}
	if c.StartupWait <= 0 {
		return errors.New("xscaler.admin-store.startup-wait must be positive")
	}
	return c.Bucket.Validate()
}

// enforceMode returns the configured push enforcement mode. An empty value
// means off. An invalid value is rejected by Validate when the admin store is
// enabled and reads as off here.
func (c *AdminStoreConfig) enforceMode() xstenant.EnforceMode {
	if c.EnforceState == "" {
		return xstenant.EnforceOff
	}
	m, err := xstenant.ParseEnforceMode(c.EnforceState)
	if err != nil {
		return xstenant.EnforceOff
	}
	return m
}

// adminStore reads per-tenant limits from the admin store and keeps them
// current. While it is enabled it is the only source of per-tenant limits.
type adminStore struct {
	cfg     AdminStoreConfig
	reader  *xstenant.Reader
	source  *xstenant.Source[*validation.Limits]
	logger  log.Logger
	runtime *runtimeconfig.Manager
}

func newAdminStore(cfg AdminStoreConfig, bkt xstenant.Bucket, validate func(*validation.Limits) error, runtime *runtimeconfig.Manager, logger log.Logger, reg prometheus.Registerer) (*adminStore, error) {
	xcfg := xstenant.DefaultConfig()
	xcfg.CacheDir = cfg.CacheDir
	xcfg.PollInterval = cfg.PollInterval
	xcfg.CacheKey = adminStoreCacheKey(cfg, xcfg.Prefix)

	reader, err := xstenant.New(xcfg, bkt, logger, reg)
	if err != nil {
		return nil, err
	}

	// The defaults must be final before the first decode.
	decode := func(_ string, raw json.RawMessage) (*validation.Limits, error) {
		l := &validation.Limits{}
		if err := json.Unmarshal(raw, l); err != nil {
			return nil, err
		}
		if validate != nil {
			if err := validate(l); err != nil {
				return nil, err
			}
		}
		return l, nil
	}

	return &adminStore{
		cfg:     cfg,
		reader:  reader,
		source:  xstenant.NewSource(reader, adminStoreEngine, decode, logger, reg),
		logger:  logger,
		runtime: runtime,
	}, nil
}

// pushGate returns the distributor push gate for the configured mode, or nil
// when enforcement is off.
func (a *adminStore) pushGate() distributor.PushGate {
	mode := a.cfg.enforceMode()
	if mode == xstenant.EnforceOff {
		return nil
	}
	return func(tenantID string) (bool, string) {
		return a.reader.CheckPush(tenantID, mode)
	}
}

// tenantLimits returns the admin store as the TenantLimits Mimir enforces.
func (a *adminStore) tenantLimits() validation.TenantLimits {
	return adminStoreTenantLimits{source: a.source}
}

type adminStoreTenantLimits struct {
	source *xstenant.Source[*validation.Limits]
}

func (l adminStoreTenantLimits) ByUserID(userID string) *validation.Limits {
	lim, _ := l.source.Get(userID)
	return lim
}

func (l adminStoreTenantLimits) AllByUserID() map[string]*validation.Limits {
	return l.source.All()
}

// adminStoreCacheKey identifies the admin store location: backend, bucket
// name and prefixes. A disk cache written under another key is ignored.
func adminStoreCacheKey(cfg AdminStoreConfig, prefix string) string {
	b := cfg.Bucket
	var name string
	switch b.Backend {
	case bucket.S3:
		name = b.S3.BucketName
	case bucket.GCS:
		name = b.GCS.BucketName
	case bucket.Azure:
		name = b.Azure.ContainerName
	case bucket.Swift:
		name = b.Swift.ContainerName
	case bucket.Filesystem:
		name = b.Filesystem.Directory
	}
	return b.Backend + "/" + name + "/" + b.StoragePrefix + "/" + prefix
}

// service runs the reader. Starting waits up to the configured startup wait
// for the first snapshot, then continues with default limits and a warning.
func (a *adminStore) service() services.Service {
	var stop func()

	starting := func(ctx context.Context) error {
		stop = a.reader.Start(ctx)
		if err := a.source.WaitApplied(ctx, a.cfg.StartupWait); err != nil {
			if ctx.Err() != nil {
				stop()
				return err
			}
			level.Warn(a.logger).Log("msg", "admin store limits not applied, continuing with default limits", "wait", a.cfg.StartupWait, "err", err)
		}
		return nil
	}

	running := func(ctx context.Context) error {
		var updates <-chan interface{}
		if a.runtime != nil {
			updates = a.runtime.CreateListenerChannel(1)
			defer a.runtime.CloseListenerChannel(updates)
			a.warnIgnoredTenantOverrides(a.runtime.GetConfig())
		}
		for {
			select {
			case <-ctx.Done():
				return nil
			case cfg, ok := <-updates:
				if !ok {
					updates = nil
					continue
				}
				a.warnIgnoredTenantOverrides(cfg)
			}
		}
	}

	stopping := func(error) error {
		if stop != nil {
			stop()
		}
		return nil
	}
	return services.NewBasicService(starting, running, stopping)
}

// readyService blocks starting until the first snapshot is applied, without a
// time limit. Modules that must not run on default limits, like the compactor
// (retention), depend on it. Other modules are not blocked.
func (a *adminStore) readyService() services.Service {
	starting := func(ctx context.Context) error {
		level.Info(a.logger).Log("msg", "waiting for the first admin store snapshot, retention must not run on default limits")
		return a.source.WaitApplied(ctx, 0)
	}
	running := func(ctx context.Context) error {
		<-ctx.Done()
		return nil
	}
	return services.NewBasicService(starting, running, nil)
}

func (a *adminStore) warnIgnoredTenantOverrides(cfg interface{}) {
	if v, ok := cfg.(*runtimeConfigValues); ok && v != nil && len(v.TenantLimits) > 0 {
		level.Warn(a.logger).Log("msg", "runtime config tenant overrides are ignored while the xscaler admin store is enabled", "tenants", len(v.TenantLimits))
	}
}

func (t *Mimir) initAdminStore() (services.Service, error) {
	if !t.Cfg.AdminStore.Enabled {
		return nil, nil
	}

	// The runtime config module has run, so the default limits, including the
	// deprecated ruler mappings, are final. Set them once, before decoding.
	validation.SetDefaultLimitsForYAMLUnmarshalling(t.Cfg.LimitsConfig)

	bkt, err := bucket.NewClient(context.Background(), t.Cfg.AdminStore.Bucket, "xscaler-admin-store", util_log.Logger, t.Registerer)
	if err != nil {
		return nil, fmt.Errorf("failed to create admin store bucket client: %w", err)
	}
	a, err := newAdminStore(t.Cfg.AdminStore, bkt, t.Cfg.ValidateLimits, t.RuntimeConfig, util_log.Logger, t.Registerer)
	if err != nil {
		return nil, err
	}
	t.AdminStore = a

	// The admin store is the only source of per-tenant limits.
	t.TenantLimits = a.tenantLimits()
	t.API.RegisterUserLimits(validation.UserLimitsHandler(t.Cfg.LimitsConfig, t.TenantLimits))
	return a.service(), nil
}

func (t *Mimir) initAdminStoreReady() (services.Service, error) {
	if t.AdminStore == nil {
		return nil, nil
	}
	return t.AdminStore.readyService(), nil
}

// pushGater is implemented by the distributor. It denies the pushes of
// tenants the push gate blocks.
type pushGater interface {
	CheckPushGate(ctx context.Context, tenantID string) (context.Context, error)
}

// gatePush runs the push gate from the gRPC method limiter, before the
// request takes an inflight slot. The tenant comes from the request metadata.
// Without it the gate runs later, in the push path.
func gatePush(ctx context.Context, dist pushReceiver, md metadata.MD) (context.Context, error) {
	g, ok := dist.(pushGater)
	if !ok {
		return ctx, nil
	}
	tenantID := getSingleMetadata(md, strings.ToLower(user.OrgIDHeaderName))
	if tenantID == "" {
		return ctx, nil
	}
	return g.CheckPushGate(ctx, tenantID)
}

// rulerPusher marks the writes of the ruler, which the push gate does not deny.
type rulerPusher struct {
	ruler.Pusher
}

func (p rulerPusher) Push(ctx context.Context, req *mimirpb.WriteRequest) (*mimirpb.WriteResponse, error) {
	return p.Pusher.Push(distributor.WithPushGateBypass(ctx), req)
}
