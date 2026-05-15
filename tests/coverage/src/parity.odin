// OXC corpus parity gate.
//
// The snapshot tests prove that kessel's current parser/semantic output has not
// drifted. This file proves the input side has not drifted either: the vendored
// corpora must be pinned to the OXC-synchronized SHAs, and the suite loaders must
// discover the exact fixture manifests we expect from OXC's coverage harness.
package coverage

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

import kessel "../../../src"

OXC_TEST262_SHA :: "ccaac100ff49d81e9ff47a75ff4c60e0bd3f262e"

ManifestStats :: struct {
	fixtures:  int,
	positive:  int,
	negative:  int,
	hash_a:    u64,
	hash_b:    u64,
}

@(test)
test_oxc_corpus_parity :: proc(t: ^testing.T) {
	root := find_kessel_root_for_parity_test()
	if root == "" {
		testing.expectf(t, false, "could not locate kessel project root")
		return
	}

	vendor, _ := filepath.join({root, "tests", "vendor"}, context.allocator)

	assert_vendor_sha(t, vendor, "test262",            OXC_TEST262_SHA)
	assert_vendor_sha(t, vendor, "babel",              BABEL_SHA)
	assert_vendor_sha(t, vendor, "typescript",         TYPESCRIPT_SHA)
	assert_vendor_sha(t, vendor, "estree-conformance", ESTREE_CONFORMANCE_SHA)

	assert_manifest(t, "test262", load_test262(vendor, context.allocator), ManifestStats{
		fixtures = 51702,
		positive = 47114,
		negative = 4588,
		hash_a   = 753947551,
		hash_b   = 658973028,
	})
	assert_manifest(t, "babel", load_babel(vendor, context.allocator), ManifestStats{
		fixtures = 3962,
		positive = 2237,
		negative = 1725,
		hash_a   = 500463058,
		hash_b   = 147854415,
	})
	assert_manifest(t, "estree", load_estree(vendor, context.allocator), ManifestStats{
		fixtures = 39,
		positive = 39,
		negative = 0,
		hash_a   = 362167104,
		hash_b   = 556920010,
	})

	ts_fixtures := load_typescript(vendor, context.allocator)
	assert_manifest(t, "typescript units", ts_fixtures, ManifestStats{
		fixtures = 16162,
		positive = 14081,
		negative = 2081,
		hash_a   = 577283493,
		hash_b   = 700734231,
	})
	assert_ts_parent_manifest(t, ts_fixtures, ManifestStats{
		fixtures = 12411,
		positive = 10751,
		negative = 1660,
		hash_a   = 632865277,
		hash_b   = 455619397,
	})
}

@(private="file")
assert_vendor_sha :: proc(t: ^testing.T, vendor_root, subdir, expected: string) {
	path, _ := filepath.join({vendor_root, subdir}, context.temp_allocator)
	actual, ok := read_git_head(path, context.temp_allocator)
	if !ok {
		testing.expectf(t, false, "missing vendored corpus git head: %s", path)
		return
	}
	testing.expectf(t, actual == expected,
		"%s corpus SHA drift: got %s, expected %s. Run tests/runners/oxc_corpus_fetch.sh and update the OXC manifest deliberately.",
		subdir, actual, expected)
}

@(private="file")
read_git_head :: proc(repo_path: string, allocator: runtime.Allocator) -> (string, bool) {
	head_path, _ := filepath.join({repo_path, ".git", "HEAD"}, allocator)
	bytes, err := os.read_entire_file_from_path(head_path, allocator)
	if err != nil { return "", false }
	head := strings.trim_space(string(bytes))
	if strings.has_prefix(head, "ref:") {
		ref := strings.trim_space(head[len("ref:"):])
		ref_path, _ := filepath.join({repo_path, ".git", ref}, allocator)
		ref_bytes, ref_err := os.read_entire_file_from_path(ref_path, allocator)
		if ref_err != nil { return "", false }
		return strings.clone(strings.trim_space(string(ref_bytes)), allocator), true
	}
	return strings.clone(head, allocator), true
}

@(private="file")
assert_manifest :: proc(t: ^testing.T, label: string, fixtures: []Fixture, expected: ManifestStats) {
	actual := fixture_manifest_stats(fixtures)
	testing.expectf(t,
		actual.fixtures == expected.fixtures &&
		actual.positive == expected.positive &&
		actual.negative == expected.negative &&
		actual.hash_a == expected.hash_a &&
		actual.hash_b == expected.hash_b,
		"%s manifest drift: got fixtures=%d positive=%d negative=%d hash=(%d,%d), expected fixtures=%d positive=%d negative=%d hash=(%d,%d)",
		label,
		actual.fixtures, actual.positive, actual.negative, actual.hash_a, actual.hash_b,
		expected.fixtures, expected.positive, expected.negative, expected.hash_a, expected.hash_b)
}

@(private="file")
fixture_manifest_stats :: proc(fixtures: []Fixture) -> ManifestStats {
	slice.sort_by(fixtures, proc(a, b: Fixture) -> bool { return a.rel < b.rel })

	h := manifest_hash_init()
	out: ManifestStats
	for f in fixtures {
		out.fixtures += 1
		if f.should_fail {
			out.negative += 1
		} else {
			out.positive += 1
		}
		manifest_hash_fixture(&h, f)
	}
	out.hash_a = h.a
	out.hash_b = h.b
	return out
}

@(private="file")
assert_ts_parent_manifest :: proc(t: ^testing.T, fixtures: []Fixture, expected: ManifestStats) {
	slice.sort_by(fixtures, proc(a, b: Fixture) -> bool { return a.rel < b.rel })

	h := manifest_hash_init()
	actual: ManifestStats
	i := 0
	for i < len(fixtures) {
		f := fixtures[i]
		parent := manifest_parent_path(f.rel)
		actual.fixtures += 1
		if f.should_fail {
			actual.negative += 1
		} else {
			actual.positive += 1
		}
		manifest_hash_string(&h, parent)
		manifest_hash_byte(&h, f.should_fail ? 'N' : 'P')
		manifest_hash_byte(&h, 0)

		i += 1
		for i < len(fixtures) && manifest_parent_path(fixtures[i].rel) == parent {
			i += 1
		}
	}
	actual.hash_a = h.a
	actual.hash_b = h.b

	testing.expectf(t,
		actual.fixtures == expected.fixtures &&
		actual.positive == expected.positive &&
		actual.negative == expected.negative &&
		actual.hash_a == expected.hash_a &&
		actual.hash_b == expected.hash_b,
		"typescript parent manifest drift: got fixtures=%d positive=%d negative=%d hash=(%d,%d), expected fixtures=%d positive=%d negative=%d hash=(%d,%d)",
		actual.fixtures, actual.positive, actual.negative, actual.hash_a, actual.hash_b,
		expected.fixtures, expected.positive, expected.negative, expected.hash_a, expected.hash_b)
}

@(private="file")
manifest_parent_path :: proc(rel: string) -> string {
	if idx := strings.index(rel, "::"); idx >= 0 { return rel[:idx] }
	return rel
}

ManifestHash :: struct {
	a: u64,
	b: u64,
}

@(private="file")
manifest_hash_init :: proc() -> ManifestHash {
	return ManifestHash{a = 1, b = 1}
}

@(private="file")
manifest_hash_byte :: proc(h: ^ManifestHash, b: byte) {
	MOD_A :: u64(1_000_000_007)
	MOD_B :: u64(1_000_000_009)
	x := u64(b) + 1
	h.a = (h.a * 257 + x) % MOD_A
	h.b = (h.b * 263 + x) % MOD_B
}

@(private="file")
manifest_hash_string :: proc(h: ^ManifestHash, s: string) {
	for b in transmute([]byte)s { manifest_hash_byte(h, b) }
}

@(private="file")
manifest_hash_fixture :: proc(h: ^ManifestHash, f: Fixture) {
	manifest_hash_string(h, f.rel)
	manifest_hash_byte(h, 0)
	manifest_hash_byte(h, f.should_fail ? 'N' : 'P')
	manifest_hash_byte(h, f.force_strict ? 'T' : 'F')
	manifest_hash_byte(h, manifest_lang_byte(f.lang))
	manifest_hash_byte(h, manifest_source_type_byte(f.source_type))
	manifest_hash_byte(h, manifest_maybe_bool_byte(f.source_is_dts))
	manifest_hash_byte(h, manifest_maybe_bool_byte(f.is_commonjs))
	manifest_hash_byte(h, 0)
}

@(private="file")
manifest_lang_byte :: proc(lang: kessel.Lang) -> byte {
	switch lang {
	case .JS:  return 'j'
	case .JSX: return 'x'
	case .TS:  return 't'
	case .TSX: return 'y'
	}
	return '?'
}

@(private="file")
manifest_source_type_byte :: proc(source_type: Maybe(kessel.SourceType)) -> byte {
	if st, ok := source_type.?; ok {
		switch st {
		case .Script: return 's'
		case .Module: return 'm'
		}
		return '?'
	}
	return 'a'
}

@(private="file")
manifest_maybe_bool_byte :: proc(v: Maybe(bool)) -> byte {
	if b, ok := v.?; ok {
		return b ? 'T' : 'F'
	}
	return 'a'
}

@(private="file")
find_kessel_root_for_parity_test :: proc() -> string {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil { return "." }
	dir := cwd
	for {
		taskfile, _ := filepath.join({dir, "Taskfile.yml"}, context.temp_allocator)
		if os.exists(taskfile) { return dir }
		parent := filepath.dir(dir, context.temp_allocator)
		if parent == dir { break }
		dir = parent
	}
	return cwd
}

_ :: fmt
