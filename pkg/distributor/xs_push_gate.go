// SPDX-License-Identifier: AGPL-3.0-only

package distributor

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/go-kit/log/level"
	"github.com/grafana/dskit/middleware"
	"github.com/grafana/dskit/tenant"

	"github.com/grafana/mimir/pkg/mimirpb"
)

// pushGateRetryAfter is the Retry-After sent with a denied push. It matches
// the 60s the xScaler proxy sends for a billing soft lock.
const pushGateRetryAfter = 60 * time.Second

// PushGate decides whether the pushes of a tenant are denied. It returns the
// reason when deny is true. A nil PushGate allows everything.
type PushGate func(tenantID string) (deny bool, reason string)

// pushGateError is returned for a push the gate denies. It maps to HTTP 429
// and codes.ResourceExhausted on every push path (remote write, OTLP, Influx
// and gRPC) through the request rate limited cause.
type pushGateError struct {
	reason string
}

func (e pushGateError) Error() string {
	return fmt.Sprintf("the push was rejected: %s", e.reason)
}

func (e pushGateError) Cause() mimirpb.ErrorCause {
	return mimirpb.ERROR_CAUSE_REQUEST_RATE_LIMITED
}

func (e pushGateError) IsSoft() bool { return false }

func (e pushGateError) RetryAfter() time.Duration { return pushGateRetryAfter }

var _ Error = pushGateError{}

// errorWithRetryAfter is implemented by errors that fix their own Retry-After.
type errorWithRetryAfter interface {
	RetryAfter() time.Duration
}

// retryAfterFromError returns the Retry-After value an error asks for.
func retryAfterFromError(err error) (string, bool) {
	var e errorWithRetryAfter
	if !errors.As(err, &e) {
		return "", false
	}
	return strconv.FormatInt(int64(e.RetryAfter().Seconds()), 10), true
}

type pushGateCtxKey int

const (
	// pushGateCheckedKey marks a context whose tenant already went through the gate.
	pushGateCheckedKey pushGateCtxKey = iota
	// pushGateBypassKey marks a push that comes from inside this process.
	pushGateBypassKey
)

// WithPushGateBypass marks the pushes of in-process callers, like the ruler
// writing recording rule results. The gate only covers external pushes. The
// mark lives in the context and cannot be set by a remote client.
func WithPushGateBypass(ctx context.Context) context.Context {
	return context.WithValue(ctx, pushGateBypassKey, true)
}

// PushGateBypassed reports whether the push comes from inside this process.
func PushGateBypassed(ctx context.Context) bool {
	v, _ := ctx.Value(pushGateBypassKey).(bool)
	return v
}

// CheckPushGate runs the gate for a tenant before the request is accounted in
// any way. It returns the error to send back, with a gRPC status, and a
// context that tells the push middleware the tenant was already checked. It
// allows everything when no gate is set.
func (d *Distributor) CheckPushGate(ctx context.Context, tenantID string) (context.Context, error) {
	if d.cfg.PushGate == nil {
		return ctx, nil
	}
	if err := d.gate(tenantID); err != nil {
		return ctx, toErrorWithGRPCStatus(err)
	}
	return context.WithValue(ctx, pushGateCheckedKey, true), nil
}

func (d *Distributor) gate(tenantID string) error {
	deny, reason := d.cfg.PushGate(tenantID)
	if !deny {
		return nil
	}
	level.Debug(d.log).Log("msg", "push denied by the push gate", "user", tenantID, "reason", reason)
	// A denied tenant can push many times a second. The error stays out of the error log.
	return middleware.DoNotLogError{Err: pushGateError{reason: reason}}
}

// pushGateMiddleware rejects the pushes of tenants the gate denies, before the
// request is read, counted or delayed by any other middleware. It is applied
// to the external push paths only: remote write, OTLP, Influx and gRPC. Pushes
// of the ruler skip it, and a tenant checked earlier (the gRPC method limiter)
// is not checked twice.
func (d *Distributor) pushGateMiddleware(next PushFunc) PushFunc {
	return WithCleanup(next, func(next PushFunc, ctx context.Context, pushReq *Request) error {
		if PushGateBypassed(ctx) {
			return next(ctx, pushReq)
		}
		if checked, _ := ctx.Value(pushGateCheckedKey).(bool); checked {
			return next(ctx, pushReq)
		}
		userID, err := tenant.TenantID(ctx)
		if err != nil {
			return err
		}
		if err := d.gate(userID); err != nil {
			return err
		}
		return next(ctx, pushReq)
	})
}

// PushExternal is PushWithMiddlewares behind the push gate. The external push
// paths (remote write, OTLP, Influx, gRPC) use it. The gate sits outside the
// delay and the inflight accounting, so a denied tenant is neither delayed nor
// counted.
func (d *Distributor) PushExternal(ctx context.Context, pushReq *Request) error {
	if d.cfg.PushGate == nil {
		return d.PushWithMiddlewares(ctx, pushReq)
	}
	return d.pushGateMiddleware(d.PushWithMiddlewares)(ctx, pushReq)
}

// isPushGateError reports whether err is a push the gate denied. The push
// handlers log these at debug, since a locked tenant retries all the time.
func isPushGateError(err error) bool {
	var e pushGateError
	return errors.As(err, &e)
}
