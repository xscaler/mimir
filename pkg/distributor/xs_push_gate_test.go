// SPDX-License-Identifier: AGPL-3.0-only

package distributor

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-kit/log"
	"github.com/grafana/dskit/httpgrpc"
	"github.com/grafana/dskit/user"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/grafana/mimir/pkg/util"
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
	d := &Distributor{cfg: Config{PushGate: gate}}
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

	st, ok := status.FromError(err)
	require.True(t, ok)
	assert.Equal(t, codes.ResourceExhausted, st.Code())
	assert.Contains(t, st.Message(), "billing_soft_locked")
}

func TestPushGate_RunsBeforeOtherMiddlewares(t *testing.T) {
	distr, cleanup := setupTestDistributor(t)
	t.Cleanup(cleanup)
	distr.cfg.PushGate = lockedGate

	push := distr.wrapPushWithMiddlewares(dummyPushFunc)
	ctx := user.InjectOrgID(context.Background(), lockedTenant)

	err := push(ctx, NewParsedRequest(nil, 1))
	var gateErr pushGateError
	require.ErrorAs(t, err, &gateErr)
	assert.Equal(t, "billing_soft_locked", gateErr.reason)
	assert.Zero(t, distr.inflightPushRequests.Load(), "a denied push must not be counted as in flight")
}

func TestPushGate_RequiresTenant(t *testing.T) {
	var passed int
	err := gatedPush(lockedGate, &passed)(context.Background(), NewParsedRequest(nil, 0))
	require.Error(t, err)
	assert.Zero(t, passed)
}
