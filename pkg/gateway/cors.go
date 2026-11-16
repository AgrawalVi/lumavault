package gateway

import "net/http"

// withCORS lets browser clients (connect-web and HTML5 video) call every Gateway route,
// answering OPTIONS preflights directly with 204.
func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Access-Control-Allow-Origin", corsAllowOrigin)
		h.Set("Access-Control-Expose-Headers", corsExposeHeaders)
		if r.Method == http.MethodOptions {
			h.Set("Access-Control-Allow-Methods", corsAllowMethods)
			h.Set("Access-Control-Allow-Headers", corsAllowHeaders)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
