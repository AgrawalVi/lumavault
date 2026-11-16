package metadata

import "fmt"

// invalidArg tags a pkg/validate error with ErrInvalidArgument so callers can match either sentinel.
func invalidArg(err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%w: %w", ErrInvalidArgument, err)
}
