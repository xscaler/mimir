// SPDX-License-Identifier: AGPL-3.0-only

package mimir

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-kit/log"
	"github.com/gorilla/mux"
	"github.com/grafana/dskit/flagext"
	"github.com/grafana/dskit/grpcutil"
	"github.com/grafana/dskit/httpgrpc"
	"github.com/grafana/dskit/server"
	"github.com/grafana/dskit/services"
	"github.com/grafana/dskit/user"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/stretchr/testify/require"
	"github.com/thanos-io/objstore"
	"github.com/xscaler/dskit/xstenant"
	"go.uber.org/atomic"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"github.com/grafana/mimir/pkg/api"
	"github.com/grafana/mimir/pkg/distributor"
	"github.com/grafana/mimir/pkg/mimirpb"
	"github.com/grafana/mimir/pkg/util/validation"
)

const adminStorePrefix = "admin/v1/"

const adminStoreFixture = `{
  "schema": 1,
  "tenants": {
    "t-alpha": {
      "cardinality_analysis_enabled": true,
      "compactor_blocks_retention_period": "2160h",
      "ingestion_burst_size": 300000,
      "ingestion_rate": 418,
      "max_global_series_per_user": 25000
    },
    "t-delta": {
      "cardinality_analysis_enabled": true
    }
  }
}`

func publishAdminStore(t *testing.T, bkt objstore.Bucket, gen int64, limits string) {
	t.Helper()
	ctx := context.Background()

	sum := sha256.Sum256([]byte(limits))
	man, err := json.Marshal(map[string]any{
		"schema":       1,
		"generation":   gen,
		"published_at": time.Unix(1_800_000_000+gen, 0).UTC(),
		"objects":      map[string]string{adminStorePrefix + "limits/mimir.json": hex.EncodeToString(sum[:])},
	})
	require.NoError(t, err)
	require.NoError(t, bkt.Upload(ctx, adminStorePrefix+"limits/mimir.json", bytes.NewReader([]byte(limits))))
	require.NoError(t, bkt.Upload(ctx, adminStorePrefix+"manifest.json", bytes.NewReader(man)))
}

func setTestDefaultLimits(t *testing.T) validation.Limits {
	t.Helper()
	var defaults validation.Limits
	flagext.DefaultValues(&defaults)
	validation.SetDefaultLimitsForYAMLUnmarshalling(defaults)
	return defaults
}

func newTestAdminStore(t *testing.T, bkt objstore.Bucket, startupWait time.Duration, logger log.Logger) *adminStore {
	t.Helper()
	cfg := AdminStoreConfig{Enabled: true, PollInterval: 10 * time.Millisecond, StartupWait: startupWait}
	a, err := newAdminStore(cfg, bkt, nil, nil, logger, prometheus.NewPedanticRegistry())
	require.NoError(t, err)
	return a
}

func runTestAdminStore(t *testing.T, a *adminStore) {
	t.Helper()
	svc := a.service()
	require.NoError(t, services.StartAndAwaitRunning(context.Background(), svc))
	t.Cleanup(func() { require.NoError(t, services.StopAndAwaitTerminated(context.Background(), svc)) })
}

type countingBucket struct {
	objstore.Bucket
	gets atomic.Int64
}

func (b *countingBucket) Get(ctx context.Context, name string) (io.ReadCloser, error) {
	b.gets.Inc()
	return b.Bucket.Get(ctx, name)
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func TestAdminStore_Decode(t *testing.T) {
	defaults := setTestDefaultLimits(t)
	bkt := objstore.NewInMemBucket()
	publishAdminStore(t, bkt, 1, adminStoreFixture)

	a := newTestAdminStore(t, bkt, 5*time.Second, log.NewNopLogger())
	runTestAdminStore(t, a)
	l := a.tenantLimits()

	alpha := l.ByUserID("t-alpha")
	require.NotNil(t, alpha)
	require.Equal(t, 418.0, alpha.IngestionRate)
	require.Equal(t, 300000, alpha.IngestionBurstSize)
	require.Equal(t, 25000, alpha.MaxGlobalSeriesPerUser)
	require.True(t, alpha.CardinalityAnalysisEnabled)

	// Fields that are not published keep the configured defaults.
	delta := l.ByUserID("t-delta")
	require.NotNil(t, delta)
	require.Equal(t, defaults.IngestionRate, delta.IngestionRate)
	require.Equal(t, defaults.MaxGlobalSeriesPerUser, delta.MaxGlobalSeriesPerUser)

	require.Nil(t, l.ByUserID("unknown"))
	require.Len(t, l.AllByUserID(), 2)
}

func TestAdminStore_DecodeFailureKeepsPreviousValue(t *testing.T) {
	setTestDefaultLimits(t)
	bkt := objstore.NewInMemBucket()
	publishAdminStore(t, bkt, 1, adminStoreFixture)
	a := newTestAdminStore(t, bkt, 5*time.Second, log.NewNopLogger())
	runTestAdminStore(t, a)
	l := a.tenantLimits()
	require.Equal(t, 418.0, l.ByUserID("t-alpha").IngestionRate)

	// t-alpha now fails to decode (unknown field), t-new has never decoded, t-delta is fine.
	publishAdminStore(t, bkt, 2, `{
  "schema": 1,
  "tenants": {
    "t-alpha": {"no_such_limit": 1},
    "t-new": {"ingestion_rate": "not a number"},
    "t-delta": {"ingestion_rate": 7}
  }
}`)
	require.Eventually(t, func() bool {
		d := l.ByUserID("t-delta")
		return d != nil && d.IngestionRate == 7
	}, 5*time.Second, 10*time.Millisecond)

	require.Equal(t, 418.0, l.ByUserID("t-alpha").IngestionRate, "failed tenant keeps its previous value")
	require.Nil(t, l.ByUserID("t-new"), "failed tenant without a previous value is skipped")
}

func TestAdminStore_StartupWaitTimesOut(t *testing.T) {
	setTestDefaultLimits(t)
	bkt := objstore.NewInMemBucket() // nothing published

	a := newTestAdminStore(t, bkt, 100*time.Millisecond, log.NewNopLogger())
	runTestAdminStore(t, a)
	require.False(t, a.source.Applied())
	require.Nil(t, a.tenantLimits().ByUserID("t-alpha"))
}

func TestAdminStore_CompactorReadyWaitsWithoutTimeout(t *testing.T) {
	setTestDefaultLimits(t)
	bkt := objstore.NewInMemBucket() // nothing published yet

	// The startup wait is tiny: the admin store itself gives up and runs on defaults.
	a := newTestAdminStore(t, bkt, 50*time.Millisecond, log.NewNopLogger())
	runTestAdminStore(t, a)
	require.False(t, a.source.Applied())

	// The compactor dependency keeps waiting, well past the startup wait.
	ready := a.readyService()
	require.NoError(t, ready.StartAsync(context.Background()))
	t.Cleanup(func() { _ = services.StopAndAwaitTerminated(context.Background(), ready) })

	time.Sleep(300 * time.Millisecond)
	require.Equal(t, services.Starting, ready.State())

	publishAdminStore(t, bkt, 1, adminStoreFixture)
	require.NoError(t, ready.AwaitRunning(context.Background()))
	require.True(t, a.source.Applied())
	require.NotNil(t, a.tenantLimits().ByUserID("t-alpha"))
}

func TestAdminStore_ReadyServiceStopsWhileWaiting(t *testing.T) {
	setTestDefaultLimits(t)
	a := newTestAdminStore(t, objstore.NewInMemBucket(), 50*time.Millisecond, log.NewNopLogger())
	runTestAdminStore(t, a)

	ready := a.readyService()
	require.NoError(t, ready.StartAsync(context.Background()))
	ready.StopAsync()
	require.Error(t, ready.AwaitTerminated(context.Background()))
}

// Only the compactor waits for the first snapshot. Everything else, including
// the targets that run next to the compactor in -target=all, does not.
func TestMimir_OnlyCompactorWaitsForAdminStoreReady(t *testing.T) {
	m := &Mimir{Cfg: *newDefaultConfig()}
	require.NoError(t, m.setupModuleManager())
	require.Contains(t, m.ModuleManager.DependenciesForModule(AdminStoreReady), AdminStore)
	require.Contains(t, m.ModuleManager.DependenciesForModule(Compactor), AdminStoreReady)
	for _, mod := range []string{Distributor, Ingester, QueryFrontend, Querier, StoreGateway, Ruler, Overrides, AdminStore} {
		require.NotContains(t, m.ModuleManager.DependenciesForModule(mod), AdminStoreReady, mod)
	}
}

// With the admin store enabled and an empty bucket, an ingest-side service in the
// same process runs on defaults after the startup wait while the compactor
// dependency keeps waiting.
func TestMimir_AdminStoreReadyModule(t *testing.T) {
	setTestDefaultLimits(t)
	cfg := newDefaultConfig()
	cfg.AdminStore.Enabled = true
	cfg.AdminStore.PollInterval = 10 * time.Millisecond
	cfg.AdminStore.StartupWait = 50 * time.Millisecond
	cfg.AdminStore.Bucket.Backend = "filesystem"
	cfg.AdminStore.Bucket.Filesystem.Directory = t.TempDir()
	m := &Mimir{Cfg: *cfg, Registerer: prometheus.NewPedanticRegistry()}
	m.Server = &server.Server{Registerer: prometheus.NewPedanticRegistry(), HTTP: mux.NewRouter()}
	require.NoError(t, m.setupModuleManager())
	_, err := m.initAPI()
	require.NoError(t, err)

	none, err := (&Mimir{}).initAdminStoreReady()
	require.NoError(t, err)
	require.Nil(t, none, "no service without an admin store")

	store, err := m.initAdminStore()
	require.NoError(t, err)
	require.NoError(t, services.StartAndAwaitRunning(context.Background(), store), "overrides side is not blocked")
	t.Cleanup(func() { require.NoError(t, services.StopAndAwaitTerminated(context.Background(), store)) })

	ready, err := m.initAdminStoreReady()
	require.NoError(t, err)
	require.NoError(t, ready.StartAsync(context.Background()))
	t.Cleanup(func() { _ = services.StopAndAwaitTerminated(context.Background(), ready) })
	time.Sleep(200 * time.Millisecond)
	require.Equal(t, services.Starting, ready.State())
}

func TestAdminStore_CancelledStartStopsReader(t *testing.T) {
	setTestDefaultLimits(t)
	bkt := &countingBucket{Bucket: objstore.NewInMemBucket()}

	a := newTestAdminStore(t, bkt, time.Hour, log.NewNopLogger())
	svc := a.service()
	require.NoError(t, svc.StartAsync(context.Background()))
	require.Eventually(t, func() bool { return bkt.gets.Load() > 2 }, 5*time.Second, 10*time.Millisecond, "reader is polling")

	svc.StopAsync()
	require.Error(t, svc.AwaitTerminated(context.Background()))

	// The reader polls every 10ms. After the service is gone it must not poll any more.
	n := bkt.gets.Load()
	time.Sleep(200 * time.Millisecond)
	require.Equal(t, n, bkt.gets.Load())
}

func TestAdminStore_StopStopsReader(t *testing.T) {
	setTestDefaultLimits(t)
	bkt := &countingBucket{Bucket: objstore.NewInMemBucket()}

	a := newTestAdminStore(t, bkt, 50*time.Millisecond, log.NewNopLogger())
	svc := a.service()
	require.NoError(t, services.StartAndAwaitRunning(context.Background(), svc))
	require.NoError(t, services.StopAndAwaitTerminated(context.Background(), svc))

	n := bkt.gets.Load()
	time.Sleep(200 * time.Millisecond)
	require.Equal(t, n, bkt.gets.Load())
}

func TestAdminStore_CacheKey(t *testing.T) {
	cfg := func(mod func(*AdminStoreConfig)) AdminStoreConfig {
		c := AdminStoreConfig{}
		c.Bucket.Backend = "s3"
		c.Bucket.S3.BucketName = "cell-a"
		mod(&c)
		return c
	}
	base := adminStoreCacheKey(cfg(func(*AdminStoreConfig) {}), "admin/v1/")
	require.Contains(t, base, "s3")
	require.Contains(t, base, "cell-a")
	require.Contains(t, base, "admin/v1/")
	require.NotEqual(t, base, adminStoreCacheKey(cfg(func(c *AdminStoreConfig) { c.Bucket.S3.BucketName = "cell-b" }), "admin/v1/"))
	require.NotEqual(t, base, adminStoreCacheKey(cfg(func(c *AdminStoreConfig) { c.Bucket.StoragePrefix = "x" }), "admin/v1/"))
	require.NotEqual(t, base, adminStoreCacheKey(cfg(func(*AdminStoreConfig) {}), "admin/v2/"))
	require.NotEqual(t, base, adminStoreCacheKey(cfg(func(c *AdminStoreConfig) { c.Bucket.Backend = "gcs"; c.Bucket.GCS.BucketName = "cell-a" }), "admin/v1/"))
}

// A cache written for one bucket is not served for another.
func TestAdminStore_CacheIgnoredForOtherBucket(t *testing.T) {
	setTestDefaultLimits(t)
	dir := t.TempDir()
	newStore := func(bucketName string, bkt objstore.Bucket) *adminStore {
		cfg := AdminStoreConfig{Enabled: true, PollInterval: 10 * time.Millisecond, StartupWait: time.Second, CacheDir: dir}
		cfg.Bucket.Backend = "s3"
		cfg.Bucket.S3.BucketName = bucketName
		a, err := newAdminStore(cfg, bkt, nil, nil, log.NewNopLogger(), prometheus.NewPedanticRegistry())
		require.NoError(t, err)
		return a
	}

	bkt := objstore.NewInMemBucket()
	publishAdminStore(t, bkt, 1, adminStoreFixture)
	a := newStore("cell-a", bkt)
	runTestAdminStore(t, a)
	require.True(t, a.source.Applied())

	same := newStore("cell-a", objstore.NewInMemBucket())
	require.True(t, same.source.Applied(), "same bucket restores from cache")

	other := newStore("cell-b", objstore.NewInMemBucket())
	require.False(t, other.source.Applied(), "another bucket ignores the cache")
}

func TestAdminStore_WarnsAboutIgnoredRuntimeTenantOverrides(t *testing.T) {
	var out lockedBuffer
	a := &adminStore{logger: log.NewLogfmtLogger(&out)}

	a.warnIgnoredTenantOverrides(&runtimeConfigValues{})
	a.warnIgnoredTenantOverrides(nil)
	require.Empty(t, out.String())

	a.warnIgnoredTenantOverrides(&runtimeConfigValues{TenantLimits: map[string]*validation.Limits{"t-omega": {}}})
	require.Equal(t, 1, strings.Count(out.String(), "runtime config tenant overrides are ignored"))
}

func TestMimir_AdminStoreModuleOrder(t *testing.T) {
	m := &Mimir{Cfg: *newDefaultConfig()}
	require.NoError(t, m.setupModuleManager())
	require.Contains(t, m.ModuleManager.DependenciesForModule(AdminStore), RuntimeConfig)
	require.Contains(t, m.ModuleManager.DependenciesForModule(Overrides), AdminStore)
}

// TestMimir_AdminStoreIsOnlyLimitsSource wires the module like Mimir does: a runtime
// config with tenant overrides and no admin store entry for one of the tenants.
func TestMimir_AdminStoreIsOnlyLimitsSource(t *testing.T) {
	setTestDefaultLimits(t)
	dir := t.TempDir()
	bktDir := filepath.Join(dir, "bucket")
	require.NoError(t, os.MkdirAll(filepath.Join(bktDir, "admin", "v1", "limits"), 0o755))
	limitsJSON := adminStoreFixture
	sum := sha256.Sum256([]byte(limitsJSON))
	man, err := json.Marshal(map[string]any{
		"schema": 1, "generation": 1, "published_at": time.Unix(1_800_000_000, 0).UTC(),
		"objects": map[string]string{adminStorePrefix + "limits/mimir.json": hex.EncodeToString(sum[:])},
	})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(bktDir, "admin", "v1", "limits", "mimir.json"), []byte(limitsJSON), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(bktDir, "admin", "v1", "manifest.json"), man, 0o600))

	for _, withRuntimeConfig := range []bool{true, false} {
		t.Run("runtime config "+map[bool]string{true: "on", false: "off"}[withRuntimeConfig], func(t *testing.T) {
			cfg := newDefaultConfig()
			cfg.Target = []string{Distributor}
			cfg.AdminStore.Enabled = true
			cfg.AdminStore.PollInterval = 10 * time.Millisecond
			cfg.AdminStore.Bucket.Backend = "filesystem"
			cfg.AdminStore.Bucket.Filesystem.Directory = bktDir

			m := &Mimir{Cfg: *cfg, Registerer: prometheus.NewPedanticRegistry()}
			m.Server = &server.Server{Registerer: prometheus.NewPedanticRegistry(), HTTP: mux.NewRouter()}
			require.NoError(t, m.setupModuleManager())
			_, err := m.initAPI()
			require.NoError(t, err)

			if withRuntimeConfig {
				rcFile := filepath.Join(dir, "runtime.yaml")
				require.NoError(t, os.WriteFile(rcFile, []byte("overrides:\n  t-alpha:\n    ingestion_rate: 1\n  t-omega:\n    ingestion_rate: 2\n"), 0o600))
				require.NoError(t, m.Cfg.RuntimeConfig.LoadPath.Set(rcFile))
				svc, err := m.initRuntimeConfig()
				require.NoError(t, err)
				require.NoError(t, services.StartAndAwaitRunning(context.Background(), svc))
				t.Cleanup(func() { require.NoError(t, services.StopAndAwaitTerminated(context.Background(), svc)) })
				require.Equal(t, 2.0, float64(m.TenantLimits.ByUserID("t-omega").IngestionRate), "runtime config limits before the admin store")
			} else {
				_, err := m.initRuntimeConfig()
				require.NoError(t, err)
				require.Nil(t, m.TenantLimits)
			}

			svc, err := m.initAdminStore()
			require.NoError(t, err)
			require.NoError(t, services.StartAndAwaitRunning(context.Background(), svc))
			t.Cleanup(func() { require.NoError(t, services.StopAndAwaitTerminated(context.Background(), svc)) })

			require.Equal(t, 418.0, m.TenantLimits.ByUserID("t-alpha").IngestionRate)
			require.Nil(t, m.TenantLimits.ByUserID("t-omega"), "runtime config tenant overrides are ignored")
			require.Len(t, m.TenantLimits.AllByUserID(), 2)

			// /api/v1/user_limits serves the admin store values.
			req := httptest.NewRequest(http.MethodGet, "/api/v1/user_limits", nil)
			req.Header.Set(user.OrgIDHeaderName, "t-alpha")
			resp := httptest.NewRecorder()
			m.Server.HTTP.ServeHTTP(resp, req)
			require.Equal(t, http.StatusOK, resp.Code)
			require.Contains(t, resp.Body.String(), `"ingestion_rate":418`)
			require.Contains(t, resp.Body.String(), `"max_global_series_per_user":25000`)
		})
	}
}

func TestAdminStore_DisabledByDefault(t *testing.T) {
	cfg := Config{}
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	cfg.RegisterFlags(fs, log.NewNopLogger())
	require.False(t, cfg.AdminStore.Enabled)
	require.Equal(t, 5*time.Second, cfg.AdminStore.PollInterval)
	require.Equal(t, 30*time.Second, cfg.AdminStore.StartupWait)
	require.NotNil(t, fs.Lookup("xscaler.admin-store.backend"))

	base := fakeTenantLimits{"a": {}}
	m := &Mimir{Cfg: cfg, TenantLimits: base}

	svc, err := m.initAdminStore()
	require.NoError(t, err)
	require.Nil(t, svc)
	require.Nil(t, m.AdminStore)

	_, err = m.initOverrides()
	require.NoError(t, err)
	require.IsType(t, fakeTenantLimits{}, m.TenantLimits)
	require.Same(t, base["a"], m.TenantLimits.ByUserID("a"))
}

type fakeTenantLimits map[string]*validation.Limits

func (f fakeTenantLimits) ByUserID(id string) *validation.Limits      { return f[id] }
func (f fakeTenantLimits) AllByUserID() map[string]*validation.Limits { return f }

func TestAdminStoreConfig_ValidateStartupWait(t *testing.T) {
	cfg := AdminStoreConfig{}
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	cfg.RegisterFlags(fs)
	cfg.Enabled = true
	cfg.Bucket.Backend = "filesystem"
	cfg.Bucket.Filesystem.Directory = t.TempDir()
	require.NoError(t, cfg.Validate())

	for _, d := range []time.Duration{0, -time.Second} {
		cfg.StartupWait = d
		require.ErrorContains(t, cfg.Validate(), "startup-wait must be positive")
	}

	// A disabled config is always valid.
	cfg.Enabled = false
	require.NoError(t, cfg.Validate())
}

func publishAdminStoreTenants(t *testing.T, bkt objstore.Bucket, gen int64, tenants string) {
	t.Helper()
	ctx := context.Background()

	objects := map[string]string{}
	for name, body := range map[string]string{"limits/mimir.json": `{"schema":1,"tenants":{}}`, "tenants.json": tenants} {
		sum := sha256.Sum256([]byte(body))
		objects[adminStorePrefix+name] = hex.EncodeToString(sum[:])
		require.NoError(t, bkt.Upload(ctx, adminStorePrefix+name, bytes.NewReader([]byte(body))))
	}
	man, err := json.Marshal(map[string]any{
		"schema": 1, "generation": gen, "published_at": time.Unix(1_800_000_000+gen, 0).UTC(), "objects": objects,
	})
	require.NoError(t, err)
	require.NoError(t, bkt.Upload(ctx, adminStorePrefix+"manifest.json", bytes.NewReader(man)))
}

func TestAdminStore_PushGate(t *testing.T) {
	setTestDefaultLimits(t)
	const tenants = `{"schema":1,"tenants":{
		"locked":{"org_id":"locked","state":"soft_locked"},
		"active":{"org_id":"active","state":"active"},
		"suspended":{"org_id":"suspended","state":"suspended"}}}`

	for _, tc := range []struct {
		mode   string
		tenant string
		deny   bool
	}{
		{"off", "locked", false},
		{"shadow", "locked", false},
		{"on", "locked", true},
		{"on", "active", false},
		{"on", "suspended", false},
		{"on", "unknown", false},
		{"shadow", "unknown", false},
	} {
		t.Run(tc.mode+"/"+tc.tenant, func(t *testing.T) {
			bkt := objstore.NewInMemBucket()
			publishAdminStoreTenants(t, bkt, 1, tenants)
			a := newTestAdminStore(t, bkt, 5*time.Second, log.NewNopLogger())
			a.cfg.EnforceState = tc.mode
			runTestAdminStore(t, a)

			gate := a.pushGate()
			if tc.mode == "off" {
				require.Nil(t, gate, "off installs no gate")
				return
			}
			require.NotNil(t, gate)
			deny, reason := gate(tc.tenant)
			require.Equal(t, tc.deny, deny)
			if tc.deny {
				require.Equal(t, "billing_soft_locked", reason)
			}
		})
	}
}

func TestAdminStore_PushGateOffByDefault(t *testing.T) {
	cfg := Config{}
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	cfg.RegisterFlags(fs, log.NewNopLogger())
	require.Equal(t, "off", cfg.AdminStore.EnforceState)
	require.NotNil(t, fs.Lookup("xscaler.admin-store.enforce-state"))

	a := newTestAdminStore(t, objstore.NewInMemBucket(), time.Second, log.NewNopLogger())
	require.Nil(t, a.pushGate())
}

func TestAdminStoreConfig_ValidateEnforceState(t *testing.T) {
	cfg := AdminStoreConfig{}
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	cfg.RegisterFlags(fs)
	cfg.Enabled = true
	cfg.Bucket.Backend = "filesystem"
	cfg.Bucket.Filesystem.Directory = t.TempDir()

	// An empty value reads as off.
	for _, v := range []string{"", "off", "shadow", "on"} {
		cfg.EnforceState = v
		require.NoError(t, cfg.Validate(), v)
	}
	cfg.EnforceState = ""
	require.Equal(t, xstenant.EnforceOff, cfg.enforceMode())

	cfg.EnforceState = "block"
	require.ErrorContains(t, cfg.Validate(), "xscaler.admin-store.enforce-state")

	// The value is only checked when the admin store is enabled.
	cfg.Enabled = false
	require.NoError(t, cfg.Validate())
}

type gatingDistributorReceiver struct {
	mockDistributorReceiver
	gateCalls int
	denied    map[string]bool
}

func (g *gatingDistributorReceiver) CheckPushGate(ctx context.Context, tenantID string) (context.Context, error) {
	g.gateCalls++
	if g.denied[tenantID] {
		return ctx, status.Error(codes.ResourceExhausted, "billing_soft_locked")
	}
	return ctx, nil
}

func TestGrpcInflightMethodLimiter_PushGate(t *testing.T) {
	md := func(tenantID string) metadata.MD {
		m := metadata.Pairs(httpgrpc.MetadataMethod, "POST", httpgrpc.MetadataURL, api.PrometheusPushEndpoint)
		if tenantID != "" {
			m.Set("x-scope-orgid", tenantID)
		}
		return m
	}
	newLimiter := func(m *gatingDistributorReceiver) *grpcInflightMethodLimiter {
		return newGrpcInflightMethodLimiter(nil, func() pushReceiver { return m })
	}

	t.Run("denied tenant takes no inflight slot", func(t *testing.T) {
		m := &gatingDistributorReceiver{denied: map[string]bool{"locked": true}}
		_, err := newLimiter(m).RPCCallStarting(context.Background(), httpgrpcHandleMethod, md("locked"))
		st, ok := grpcutil.ErrorToStatus(err)
		require.True(t, ok)
		require.Equal(t, codes.ResourceExhausted, st.Code())
		require.Equal(t, 0, m.startCalls)
	})

	t.Run("allowed tenant continues to the inflight check", func(t *testing.T) {
		m := &gatingDistributorReceiver{denied: map[string]bool{"locked": true}}
		_, err := newLimiter(m).RPCCallStarting(context.Background(), httpgrpcHandleMethod, md("active"))
		require.NoError(t, err)
		require.Equal(t, 1, m.gateCalls)
		require.Equal(t, 1, m.startCalls)
	})

	t.Run("no tenant in the metadata leaves the gate to the push path", func(t *testing.T) {
		m := &gatingDistributorReceiver{denied: map[string]bool{"locked": true}}
		_, err := newLimiter(m).RPCCallStarting(context.Background(), httpgrpcHandleMethod, md(""))
		require.NoError(t, err)
		require.Equal(t, 0, m.gateCalls)
		require.Equal(t, 1, m.startCalls)
	})
}

type recordingPusher struct {
	bypassed bool
}

func (p *recordingPusher) Push(ctx context.Context, _ *mimirpb.WriteRequest) (*mimirpb.WriteResponse, error) {
	p.bypassed = distributor.PushGateBypassed(ctx)
	return &mimirpb.WriteResponse{}, nil
}

func TestRulerPusher_BypassesPushGate(t *testing.T) {
	p := &recordingPusher{}
	_, err := rulerPusher{p}.Push(context.Background(), &mimirpb.WriteRequest{})
	require.NoError(t, err)
	require.True(t, p.bypassed)
}
