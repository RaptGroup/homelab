package main

import (
	"flag"
	"log"

	distributor "github.com/haljac/homelab/hcos-tls-distributor"
)

func createCertPathsOption() distributor.Option {
	capath := flag.String("capath", "", "-capath=<path to ca pem>")
	certpath := flag.String("certpath", "", "-certpath=<path to tls cert>")
	keypath := flag.String("keypath", "", "-keypath=<path to tls key>")
	flag.Parse()

	if *capath == "" && *certpath == "" && *keypath == "" {
		return nil
	}

	if *capath == "" || *certpath == "" || *keypath == "" {
		log.Fatalf("If using command-line arguments, all cert paths are required.")
	}

	return distributor.WithCertificatePaths(
		*capath,
		*certpath,
		*keypath,
	)
}

func main() {
	endpoints := []distributor.Endpoint{
		distributor.Endpoint("https://hypercore1.homelab.internal"),
		distributor.Endpoint("https://hypercore2.homelab.internal"),
	}

	options := []distributor.Option{
		distributor.WithHypercoreCredentials(
			"admin",
			"admin",
		),
	}

	certPathsOption := createCertPathsOption()
	if certPathsOption != nil {
		options = append(options, certPathsOption)
	}

	d := distributor.New(endpoints, options...)
	d.Run()
}
