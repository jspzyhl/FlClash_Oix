package main

import (
	"net"
	"strings"
	"sync"
	"github.com/metacubex/mihomo/constant"
)

var (
	maskedAddrs []string
	maskLock    sync.RWMutex
	isOixCloud  bool
)

func setMaskedAddrs(isOix bool, proxies map[string]constant.Proxy) {
	maskLock.Lock()
	defer maskLock.Unlock()

	isOixCloud = isOix
	maskedAddrs = nil
	if !isOix {
		return
	}

	seen := make(map[string]bool)
	for _, proxy := range proxies {
		addr := proxy.Addr()
		host, _, e := net.SplitHostPort(addr)
		var val string
		if e == nil && host != "" {
			val = host
		} else if addr != "" {
			val = addr
		}

		if val != "" && len(val) >= 4 && val != "127.0.0.1" && val != "localhost" && !seen[val] {
			seen[val] = true
			maskedAddrs = append(maskedAddrs, val)
		}
	}
}

func MaskLogPayload(payload string) string {
	maskLock.RLock()
	defer maskLock.RUnlock()
	if !isOixCloud || len(maskedAddrs) == 0 {
		return payload
	}
	for _, target := range maskedAddrs {
		payload = strings.ReplaceAll(payload, target, "***")
	}
	return payload
}
