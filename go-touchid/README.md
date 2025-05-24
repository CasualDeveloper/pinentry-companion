# Authenticating with TouchID

```golang
package main

import (
	"log"

	touchid "github.com/ikitsuchi/go-touchid"
)

func main() {
	ok, err := touchid.Authenticate("access llamas", "cancel", "fallback")
	if err != nil {
		log.Fatal(err)
	}

	if ok {
		log.Printf("Authenticated")
	} else {
		log.Fatal("Failed to authenticate")
	}
}
```

![Screenshot](https://lachlan.me/s/9TMZWTYGikXoeCHm8RBgi8Bb0o4R1Bz6uI.png)
