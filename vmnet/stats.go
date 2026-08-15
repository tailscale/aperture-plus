package vmnet

import (
	"expvar"
	"reflect"
	"sync"
	"sync/atomic"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

var publishStackStatsOnce sync.Once

// publishStackStats attaches the gVisor stack's stats.Stats() to the
// "gvisor" key of the process expvar map. Called once from NewNetStack.
// The default json encoder can't reach *tcpip.StatCounter's private atomic
// counter, so we walk the Stats struct via reflection and turn it into a
// nested map of uint64s.
func publishStackStats(s *stack.Stack) {
	expvar.Publish("gvisor", expvar.Func(func() any {
		stats := s.Stats()
		return countersToMap(reflect.ValueOf(&stats).Elem())
	}))
}

var statCounterType = reflect.TypeOf((*tcpip.StatCounter)(nil))

func countersToMap(v reflect.Value) any {
	switch v.Kind() {
	case reflect.Ptr:
		if v.IsNil() {
			return nil
		}
		if v.Type() == statCounterType {
			return v.Interface().(*tcpip.StatCounter).Value()
		}
		return countersToMap(v.Elem())
	case reflect.Struct:
		out := make(map[string]any, v.NumField())
		for i := 0; i < v.NumField(); i++ {
			f := v.Type().Field(i)
			if !f.IsExported() {
				continue
			}
			if sub := countersToMap(v.Field(i)); sub != nil {
				out[f.Name] = sub
			}
		}
		if len(out) == 0 {
			return nil
		}
		return out
	default:
		return nil
	}
}

// Live counters exposed via /debug/vars when the daemon is run with a debug
// listener. They're deliberately coarse: the point is to be able to answer
// questions like "why is this hung — are we leaking gVisor endpoints?" from
// a running process, not to build a metrics pipeline.
var (
	metricTCPForwarderOpen   atomic.Int64 // gVisor accept -> tsnet.Dial connections currently open
	metricTCPForwarderTotal  atomic.Int64 // lifetime accepts (successful CreateEndpoint)
	metricTCPForwarderFailed atomic.Int64 // lifetime accepts that failed CreateEndpoint or Dial
	metricUDPSessionsOpen    atomic.Int64 // entries currently in udpSessions map
	metricUDPSessionsTotal   atomic.Int64 // lifetime UDP sessions opened
	metricUDPSessionsEvicted atomic.Int64 // lifetime UDP sessions expired by the cleaner
	metricInboundTCPTotal    atomic.Int64 // lifetime tsnet.Listen accepts (from --forward)
)

func init() {
	m := expvar.NewMap("netd")
	// atomic.Int64 doesn't satisfy expvar.Var, so wrap.
	pub := func(name string, v *atomic.Int64) {
		m.Set(name, expvar.Func(func() any { return v.Load() }))
	}
	pub("tcp_forwarder_open", &metricTCPForwarderOpen)
	pub("tcp_forwarder_total", &metricTCPForwarderTotal)
	pub("tcp_forwarder_failed", &metricTCPForwarderFailed)
	pub("udp_sessions_open", &metricUDPSessionsOpen)
	pub("udp_sessions_total", &metricUDPSessionsTotal)
	pub("udp_sessions_evicted", &metricUDPSessionsEvicted)
	pub("inbound_tcp_total", &metricInboundTCPTotal)
}
