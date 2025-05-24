package touchid

/*
#cgo CFLAGS: -x objective-c -fmodules -fblocks
#cgo LDFLAGS: -framework CoreFoundation -framework LocalAuthentication -framework Foundation
#include <stdlib.h>
#include <stdio.h>
#import <LocalAuthentication/LocalAuthentication.h>

int isTouchIDAvailable() {
    int result = 0;
    bool success = [[[LAContext alloc] init] canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:nil];
    if (success) {
        return 1;
    }

    return 0;
}

int Authenticate(char const* reason, char const* cancel_title, char const* fallback_title) {
  LAContext *myContext = [[LAContext alloc] init];
  NSError *authError = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  NSString *nsReason = [NSString stringWithUTF8String:reason];
  __block int result = 0;

  if (cancel_title != NULL) {
    myContext.localizedCancelTitle = [NSString stringWithUTF8String:cancel_title];
  }

  if (fallback_title != NULL) {
    myContext.localizedFallbackTitle = [NSString stringWithUTF8String:fallback_title];
  }

  if ([myContext canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&authError]) {
    [myContext evaluatePolicy:LAPolicyDeviceOwnerAuthentication
      localizedReason:nsReason
      reply:^(BOOL success, NSError *error) {
        if (success) {
          result = 1;
        } else {
          if (error.code == kLAErrorUserCancel) {
            result = 3;
          } else if (error.code == kLAErrorUserFallback) {
            result = 4;
          } else {
            result = 2;
          }
        }
        dispatch_semaphore_signal(sema);
      }];
  }

  dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
  dispatch_release(sema);
  return result;
}
*/
import (
	"C"
)
import (
	"errors"
	"unsafe"
)

var (
	ErrUserCancel   = errors.New("user cancel")
	ErrUserFallback = errors.New("user fallback")
)

// IsTouchIDAvailable checks if Touch ID is available in the current device
func IsTouchIDAvailable() bool {
	result := C.isTouchIDAvailable()

	return result == 1
}

func Authenticate(reason string, cancel_title string, fallback_title string) (bool, error) {
	reasonStr := C.CString(reason)
	cancel_titleStr := C.CString(cancel_title)
	fallback_titleStr := C.CString(fallback_title)
	defer C.free(unsafe.Pointer(reasonStr))
	defer C.free(unsafe.Pointer(cancel_titleStr))
	defer C.free(unsafe.Pointer(fallback_titleStr))

	result := C.Authenticate(reasonStr, cancel_titleStr, fallback_titleStr)
	switch result {
	case 1:
		return true, nil
	case 2:
		return false, nil
	case 3:
		return false, ErrUserCancel
	case 4:
		return false, ErrUserFallback
	}

	return false, errors.New("Error occurred accessing biometrics")
}
