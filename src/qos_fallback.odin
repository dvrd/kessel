package kessel

// The Darwin implementation uses Apple's pthread QoS extension.
when ODIN_OS != .Darwin {
	pin_to_p_core :: proc() {}
}
