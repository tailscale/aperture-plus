# TailBrowser

Just a simple wrapper around WebKit to proxy requests via 
userspace Tailscale.

Browse URLs on your Tailnet without a VPN!

## Building

* Requires go 1.26.3
* Requires iOS 26.0

Grab the tailscalekit submodule... 

``` bash
$ git submodule update --init
$ cd ThirdParty/libtailscale/swift
$ make ios-fat
```

Build the TailBrowser scheme in xCode 26.2

