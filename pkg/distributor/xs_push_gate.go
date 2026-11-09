// SPDX-License-Identifier: AGPL-3.0-only

package distributor

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

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

// pushGateMiddleware rejects the pushes of tenants the gate denies, before the
// request is read or counted by any other middleware. Every write path goes
// through the push wrappers, so this covers remote write, OTLP, Influx and gRPC.
func (d *Distributor) pushGateMiddleware(next PushFunc) PushFunc {
	return WithCleanup(next, func(next PushFunc, ctx context.Context, pushReq *Request) error {
		userID, err := tenant.TenantID(ctx)
		if err != nil {
			return err
		}
		if deny, reason := d.cfg.PushGate(userID); deny {
			return pushGateError{reason: reason}
		}
		return next(ctx, pushReq)
	})
}
