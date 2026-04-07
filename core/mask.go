package main

import (
	"net"
	"strings"
	"sync"

	"github.com/metacubex/mihomo/constant"
)

var (
	maskLock    sync.RWMutex
	isOixCloud  bool
	logReplacer *strings.Replacer
)

func setMaskedAddrs(isOix bool, proxies map[string]constant.Proxy) {
	maskLock.Lock()
	defer maskLock.Unlock()

	isOixCloud = isOix
	logReplacer = nil
	if !isOix {
		return
	}

	seen := make(map[string]bool)
	var replacerArgs []string
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
			replacerArgs = append(replacerArgs, val, "***")
		}
	}

	if len(replacerArgs) > 0 {
		logReplacer = strings.NewReplacer(replacerArgs...)
	}
}

func MaskLogPayload(payload string) string {
	maskLock.RLock()
	defer maskLock.RUnlock()
	if !isOixCloud || logReplacer == nil {
		return payload
	}
	return logReplacer.Replace(payload)
}
