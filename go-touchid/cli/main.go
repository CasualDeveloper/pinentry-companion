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
