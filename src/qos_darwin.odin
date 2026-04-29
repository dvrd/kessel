// QoS pinning for Apple Silicon — bias the thread to P-cores.
//
// On M-series chips, the kernel scheduler routes threads to E-cores
// (efficiency cores) or P-cores (performance cores) based on the
// thread's QoS class. The default QoS for a CLI tool is
// `QOS_CLASS_DEFAULT`, which can land on E-cores under system load
// (e.g. when the user has many other processes running).
//
// `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)`
// raises the QoS to the highest interactive tier, which biases the
// scheduler toward P-cores even under load. This is the same QoS
// used by the foreground UI thread of the active app.
//
// Predicted gain on bench: 0–10 % depending on system load. On an
// otherwise idle machine the kernel already routes a lone CPU-bound
// thread to a P-core, so the speedup is small (or zero). On a busy
// machine — many tabs, video, builds — the speedup can be significant
// because without the QoS hint the parser may share a P-core or get
// demoted to an E-core mid-run.
//
// Cost: one syscall at process start (~1 µs). Zero recurring cost.
//
// Real-world parsers (LSPs, build tools) almost always run alongside
// other workload, so this is a "free" win for the common case.

package main

when ODIN_OS == .Darwin {
	foreign import qos_lib "system:System"

	// qos_class_t values from <sys/qos.h>.
	// These ARE stable: the values encode (priority_band << 4) | priority,
	// and Apple's docs explicitly call out the integer encoding.
	QOS_CLASS_USER_INTERACTIVE :: 0x21  // ~33 — highest, foreground UI
	QOS_CLASS_USER_INITIATED   :: 0x19  // ~25 — async user-driven work
	QOS_CLASS_DEFAULT          :: 0x15  // ~21 — process default
	QOS_CLASS_UTILITY          :: 0x11  // ~17 — long-running, bg-OK
	QOS_CLASS_BACKGROUND       :: 0x09  //  ~9 — maintenance

	@(default_calling_convention="c")
	foreign qos_lib {
		// Sets the QoS class of the calling thread.
		// `relative_priority` is in [-15, 0]; 0 = highest within class.
		// Returns 0 on success, errno on failure.
		pthread_set_qos_class_self_np :: proc(qos_class: i32, relative_priority: i32) -> i32 ---
	}

	pin_to_p_core :: proc() {
		// Best-effort: ignore the return value. If the call fails (e.g.
		// future macOS removes the symbol) we just keep default QoS.
		// User-interactive is the highest tier and is what the
		// foreground UI thread uses, so it's safe to request even for
		// a CLI tool — the kernel will downgrade if the system is
		// truly oversubscribed.
		_ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
	}
} else {
	// On non-Darwin, P/E asymmetry isn't a thing on the platforms we
	// target (Linux x86-64, Linux ARM64 server). No-op.
	pin_to_p_core :: proc() {}
}
