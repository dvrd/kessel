// ECMA-262 §14.12.1 — a SwitchStatement with more than one DefaultClause
// is a SyntaxError regardless of strict/sloppy mode.
switch (x) {
	case 1:
		break;
	default:
		break;
	default:
		break;
}
