// SPDX-License-Identifier: AGPL-3.0-only

package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-kit/log"
	"github.com/gorilla/mux"
	"github.com/grafana/dskit/server"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/stretchr/testify/require"

	"github.com/grafana/mimir/pkg/querier/tenantfederation"
)

func newAuthorizerTestAPI(t *testing.T) *API {
	t.Helper()
	srv := &server.Server{Registerer: prometheus.NewPedanticRegistry(), HTTP: mux.NewRouter()}
	a, err := New(Config{}, tenantfederation.Config{}, server.Config{}, srv, log.NewNopLogger(), nil)
	require.NoError(t, err)
	return a
}

func TestAPI_RequestAuthorizer(t *testing.T) {
	a := newAuthorizerTestAPI(t)
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	// Registered before the authorizer is set: it still applies.
	a.RegisterRoute("/authed", ok, true, false, http.MethodGet)
	a.RegisterRoutesWithPrefix("/prefixed/", ok, true, false, 0, http.MethodGet)
	a.RegisterRoute("/open", ok, false, false, http.MethodGet)

	serve := func(path string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("X-Scope-OrgID", "t1")
		rec := httptest.NewRecorder()
		a.server.HTTP.ServeHTTP(rec, req)
		return rec
	}

	require.Equal(t, http.StatusOK, serve("/authed").Code, "no authorizer set")

	calls := 0
	a.SetRequestAuthorizer(func(w http.ResponseWriter, r *http.Request) bool {
		calls++
		if r.Header.Get("X-Deny") != "" {
			http.Error(w, "denied", http.StatusForbidden)
			return false
		}
		r.Header.Set("X-Scope-OrgID", "rewritten")
		return true
	})

	require.Equal(t, http.StatusOK, serve("/authed").Code)
	require.Equal(t, 1, calls, "an authenticated route is checked once")
	require.Equal(t, http.StatusOK, serve("/prefixed/x").Code)
	require.Equal(t, 2, calls)

	require.Equal(t, http.StatusOK, serve("/open").Code)
	require.Equal(t, 2, calls, "an unauthenticated route is not checked")

	// A denied request gets the authorizer's answer and nothing else runs.
	reached := false
	a.RegisterRoute("/probe", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		require.Equal(t, "rewritten", r.Header.Get("X-Scope-OrgID"))
	}), true, false, http.MethodGet)
	req := httptest.NewRequest(http.MethodGet, "/probe", nil)
	req.Header.Set("X-Deny", "1")
	rec := httptest.NewRecorder()
	a.server.HTTP.ServeHTTP(rec, req)
	require.Equal(t, http.StatusForbidden, rec.Code)
	require.False(t, reached)
	req = httptest.NewRequest(http.MethodGet, "/probe", nil)
	req.Header.Set("X-Scope-OrgID", "t1")
	a.server.HTTP.ServeHTTP(httptest.NewRecorder(), req)
	require.True(t, reached, "the header set by the authorizer reaches the handler")

	// Requests marked internal skip it.
	before := calls
	req = httptest.NewRequest(http.MethodGet, "/authed", nil)
	req.Header.Set("X-Scope-OrgID", "t1")
	rec = httptest.NewRecorder()
	SkipRequestAuthorizer(a.server.HTTP).ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)
	require.Equal(t, before, calls)

	a.SetRequestAuthorizer(nil)
	require.Equal(t, http.StatusOK, serve("/authed").Code)
	require.Equal(t, before, calls, "removed")
}

func TestAPI_AuthMiddlewareDoesNotCarryRequestAuthorizer(t *testing.T) {
	a := newAuthorizerTestAPI(t)
	calls := 0
	a.SetRequestAuthorizer(func(http.ResponseWriter, *http.Request) bool { calls++; return false })

	// Internal routers wrap AuthMiddleware directly and must not be checked.
	h := a.AuthMiddleware.Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("X-Scope-OrgID", "t1")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)
	require.Zero(t, calls)
}
