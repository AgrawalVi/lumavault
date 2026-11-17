package gateway

import (
	"context"
	"strings"

	"connectrpc.com/connect/v2"
	lumavaultv1 "github.com/lumavault/lumavault/gen/go/lumavault/v1"
	"github.com/lumavault/lumavault/pkg/ticket"
)

// Option configures NewHandler.
type Option func(*gateway)

// WithTicketAuth turns on storage ticket checks. Without it every call is allowed, as before
// tickets existed, so local runs need no secrets.
func WithTicketAuth(verifier *ticket.Verifier, serviceKey string) Option {
	return func(g *gateway) {
		g.auth = &gatewayAuth{verifier: verifier, serviceKey: serviceKey}
	}
}

type gatewayAuth struct {
	verifier   *ticket.Verifier
	serviceKey string
}

// credential is who is calling: apps/api with the service key, or a client with a ticket.
type credential struct {
	service bool
	claims  ticket.Claims
}

func (c credential) upload() bool { return c.service || c.claims.Kind == ticket.KindUpload }

func (c credential) readsObject(id string) bool {
	return c.service || (c.claims.Kind == ticket.KindRead && c.claims.ObjectID != "" && c.claims.ObjectID == id)
}

// credentialFrom checks a service key header or a bearer ticket. With checks off it returns
// a service credential, which allows everything.
func (a *gatewayAuth) credentialFrom(authorization, serviceKey, queryToken string) (credential, *connect.Error) {
	if a == nil {
		return credential{service: true}, nil
	}
	if serviceKey != "" {
		if !ticket.ServiceKeyMatches(a.serviceKey, serviceKey) {
			return credential{}, connect.NewError(connect.CodeUnauthenticated, "invalid service key")
		}
		return credential{service: true}, nil
	}
	token := bearerToken(authorization)
	if token == "" {
		token = queryToken
	}
	if token == "" {
		return credential{}, connect.NewError(connect.CodeUnauthenticated, "storage ticket required")
	}
	claims, err := a.verifier.Verify(token)
	if err != nil {
		return credential{}, connect.NewError(connect.CodeUnauthenticated, err.Error())
	}
	return credential{claims: claims}, nil
}

func bearerToken(authorization string) string {
	scheme, token, ok := strings.Cut(strings.TrimSpace(authorization), " ")
	if !ok || !strings.EqualFold(scheme, bearerScheme) {
		return ""
	}
	return strings.TrimSpace(token)
}

// rpcCredential reads the caller's credential from the RPC's request headers.
func (g *gateway) rpcCredential(ctx context.Context) (credential, error) {
	var authorization, serviceKey string
	if info, ok := connect.CallInfoForServerContext(ctx); ok {
		authorization = info.RequestHeader().Get(headerAuthorization)
		serviceKey = info.RequestHeader().Get(headerServiceKey)
	}
	cred, err := g.auth.credentialFrom(authorization, serviceKey, "")
	if err != nil {
		return credential{}, err
	}
	return cred, nil
}

// requireService allows only apps/api, which holds the service key.
func (g *gateway) requireService(ctx context.Context, rpc string) error {
	cred, err := g.rpcCredential(ctx)
	if err != nil {
		return err
	}
	if !cred.service {
		return denied(rpc)
	}
	return nil
}

func denied(what string) error {
	return connect.NewError(connect.CodePermissionDenied, "storage ticket does not allow "+what)
}

// allowCommit enforces an upload ticket's namespace and size cap, and requires skip_dedup so
// every household gets its own manifest.
func allowCommit(c credential, req *lumavaultv1.CommitObjectRequest) error {
	if c.service {
		return nil
	}
	if c.claims.Kind != ticket.KindUpload {
		return denied("CommitObject")
	}
	if int32(req.GetNamespace()) != c.claims.Namespace {
		return denied("this namespace")
	}
	if req.GetSizeBytes() > c.claims.MaxSizeBytes {
		return denied("an object this large")
	}
	if !req.GetSkipDedup() {
		return denied("commits without skip_dedup")
	}
	return nil
}
