// SPDX-License-Identifier: AGPL-3.0-only

package distributor

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-kit/log"
	"github.com/grafana/dskit/flagext"
	"github.com/grafana/dskit/grpcutil"
	"github.com/grafana/dskit/httpgrpc"
	"github.com/grafana/dskit/middleware"
	"github.com/grafana/dskit/user"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/common/model"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc/codes"

	"github.com/grafana/mimir/pkg/util"
	"github.com/grafana/mimir/pkg/util/validation"
)

const lockedTenant = "locked"

func lockedGate(tenantID string) (bool, string) {
	if tenantID == lockedTenant {
		return true, "billing_soft_locked"
	}
	return false, "allowed"
}

// gatedPush returns a push func that counts the requests that pass the gate.
func gatedPush(gate PushGate, passed *int) PushFunc {
	d := &Distributor{cfg: Config{PushGate: gate}, log: log.NewNopLogger()}
	return d.pushGateMiddleware(func(context.Context, *Request) error {
		*passed++
		return nil
	})
}

type gatePath struct {
	name    string
	handler func(push PushFunc) http.Handler
	request func(t *testing.T, tenantID string) *http.Request
	denied  int
	allowed int
}

func gatePaths() []gatePath {
	otlpBody := []byte(`{"resourceMetrics": [{"scopeMetrics": [{"metrics": [{"name": "metric", "gauge": {"dataPoints": [{"timeUnixNano": "1679912463340000000", "asDouble": 10.66}]}}]}]}]}`)
	return []gatePath{
		{
			name: "remote write",
			handler: func(push PushFunc) http.Handler {
				return Handler(100000, nil, nil, false, false, nil, RetryConfig{}, push, nil, log.NewNopLogger())
			},
			request: func(t *testing.T, tenantID string) *http.Request {
				req := createRequest(t, createPrometheusRemoteWriteProtobuf(t))
				return req.WithContext(user.InjectOrgID(req.Context(), tenantID))
			},
			denied:  http.StatusTooManyRequests,
			allowed: http.StatusOK,
		},
		{
			name: "otlp",
			handler: func(push PushFunc) http.Handler {
				reg := prometheus.NewRegistry()
				return OTLPHandler(100000, util.NewBufferPool(0), nil, false, otlpLimitsMock{}, nil, nil, RetryConfig{}, nil, push, newPushMetrics(reg), reg, log.NewNopLogger())
			},
			request: func(t *testing.T, tenantID string) *http.Request {
				req, err := httpgrpc.ToHTTPRequest(user.InjectOrgID(context.Background(), tenantID), &httpgrpc.HTTPRequest{
					Method:  "POST",
					Headers: []*httpgrpc.Header{{Key: "Content-Type", Values: []string{"application/json"}}},
					Url:     "/otlp/v1/metrics",
					Body:    otlpBody,
				})
				require.NoError(t, err)
				return req
			},
			denied:  http.StatusTooManyRequests,
			allowed: http.StatusOK,
		},
		{
			name: "influx",
			handler: func(push PushFunc) http.Handler {
				return InfluxHandler(100000, util.NewBufferPool(0), nil, RetryConfig{}, push, nil, log.NewNopLogger())
			},
			request: func(_ *testing.T, tenantID string) *http.Request {
				ctx := user.InjectOrgID(context.Background(), tenantID)
				return httptest.NewRequest("POST", "/api/v1/push/influx/write", bytes.NewReader([]byte("measurement,t1=v1 f1=2 1465839830100400200"))).WithContext(ctx)
			},
			denied:  http.StatusTooManyRequests,
			allowed: http.StatusNoContent,
		},
	}
}

func TestPushGate_HTTPPaths(t *testing.T) {
	for _, p := range gatePaths() {
		t.Run(p.name, func(t *testing.T) {
			t.Run("locked tenant is denied", func(t *testing.T) {
				var passed int
				resp := httptest.NewRecorder()
				p.handler(gatedPush(lockedGate, &passed)).ServeHTTP(resp, p.request(t, lockedTenant))

				assert.Equal(t, p.denied, resp.Code)
				assert.Equal(t, "60", resp.Header().Get("Retry-After"))
				assert.Zero(t, passed)
				if p.name != "influx" {
					assert.Contains(t, resp.Body.String(), "billing_soft_locked")
				}
			})
			t.Run("other tenant is allowed", func(t *testing.T) {
				var passed int
				resp := httptest.NewRecorder()
				p.handler(gatedPush(lockedGate, &passed)).ServeHTTP(resp, p.request(t, "active"))

				assert.Equal(t, p.allowed, resp.Code)
				assert.Equal(t, 1, passed)
			})
		})
	}
}

func TestPushGate_GRPCStatus(t *testing.T) {
	d := &Distributor{}
	err := d.handlePushError(pushGateError{reason: "billing_soft_locked"})

	st, ok := grpcutil.ErrorToStatus(err)
	require.True(t, ok)
	assert.Equal(t, codes.ResourceExhausted, st.Code())
	assert.Contains(t, st.Message(), "billing_soft_locked")
}

func TestPushGate_RunsBeforeOtherMiddlewares(t *testing.T) {
	distr, cleanup := setupTestDistributor(t)
	t.Cleanup(cleanup)
	distr.cfg.PushGate = lockedGate
	distr.PushWithMiddlewares = distr.wrapPushWithMiddlewares(dummyPushFunc)
	ctx := user.InjectOrgID(context.Background(), lockedTenant)

	err := distr.PushExternal(ctx, NewParsedRequest(nil, 1))
	var gateErr pushGateError
	require.ErrorAs(t, err, &gateErr)
	assert.Equal(t, "billing_soft_locked", gateErr.reason)
	assert.Zero(t, distr.inflightPushRequests.Load(), "a denied push must not be counted as in flight")
}

func TestPushGate_DeniedPushIsNotDelayed(t *testing.T) {
	distr, cleanup := setupTestDistributor(t)
	t.Cleanup(cleanup)
	distr.cfg.PushGate = lockedGate
	distr.PushWithMiddlewares = distr.wrapPushWithMiddlewares(dummyPushFunc)
	var slept time.Duration
	distr.sleep = func(d time.Duration) { slept += d }
	distr.limits = validation.NewOverrides(func() validation.Limits {
		l := validation.Limits{}
		flagext.DefaultValues(&l)
		l.IngestionArtificialDelay = model.Duration(time.Second)
		return l
	}(), nil)

	err := distr.PushExternal(user.InjectOrgID(context.Background(), lockedTenant), NewParsedRequest(nil, 1))
	require.Error(t, err)
	assert.Zero(t, slept, "a denied push must not be delayed")
}

func TestPushGate_ErrorIsNotLoggedAsError(t *testing.T) {
	var passed int
	err := gatedPush(lockedGate, &passed)(user.InjectOrgID(context.Background(), lockedTenant), NewParsedRequest(nil, 0))
	require.Error(t, err)

	var dnl middleware.DoNotLogError
	require.ErrorAs(t, err, &dnl)
	shouldLog, _ := dnl.ShouldLog(context.Background())
	assert.False(t, shouldLog)
	var gateErr pushGateError
	require.ErrorAs(t, err, &gateErr)
}

func TestPushGate_RulerBypass(t *testing.T) {
	distr, cleanup := setupTestDistributor(t)
	t.Cleanup(cleanup)
	distr.cfg.PushGate = lockedGate
	var passed int
	distr.PushWithMiddlewares = func(context.Context, *Request) error {
		passed++
		return nil
	}
	ctx := user.InjectOrgID(context.Background(), lockedTenant)

	require.Error(t, distr.PushExternal(ctx, NewParsedRequest(nil, 1)))
	assert.Zero(t, passed)

	require.NoError(t, distr.PushExternal(WithPushGateBypass(ctx), NewParsedRequest(nil, 1)))
	assert.Equal(t, 1, passed)
}

func TestPushGate_CheckedOnce(t *testing.T) {
	var calls int
	gate := func(string) (bool, string) {
		calls++
		return false, "allowed"
	}
	var passed int
	d := &Distributor{cfg: Config{PushGate: gate}, log: log.NewNopLogger()}
	d.PushWithMiddlewares = func(context.Context, *Request) error {
		passed++
		return nil
	}

	ctx, err := d.CheckPushGate(user.InjectOrgID(context.Background(), "active"), "active")
	require.NoError(t, err)
	require.NoError(t, d.PushExternal(ctx, NewParsedRequest(nil, 1)))
	assert.Equal(t, 1, calls, "the gate must run once for a request checked by the method limiter")
	assert.Equal(t, 1, passed)
}

func TestPushGate_CheckPushGate(t *testing.T) {
	d := &Distributor{cfg: Config{PushGate: lockedGate}, log: log.NewNopLogger()}

	_, err := d.CheckPushGate(context.Background(), lockedTenant)
	st, ok := grpcutil.ErrorToStatus(err)
	require.True(t, ok)
	assert.Equal(t, codes.ResourceExhausted, st.Code())

	_, err = d.CheckPushGate(context.Background(), "active")
	require.NoError(t, err)

	d.cfg.PushGate = nil
	_, err = d.CheckPushGate(context.Background(), lockedTenant)
	require.NoError(t, err)
}

func TestPushGate_RequiresTenant(t *testing.T) {
	var passed int
	err := gatedPush(lockedGate, &passed)(context.Background(), NewParsedRequest(nil, 0))
	require.Error(t, err)
	assert.Zero(t, passed)
}
