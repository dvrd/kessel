// In-process codegen latency loop. Mirrors `oxc_microbench` (parser) and
// Kessel's `microbench codegen` so the three measurements compare apples
// to apples:
//
//   * parse() runs once outside the timed loop, so its cost is excluded.
//   * The timed loop runs `Codegen::new().build(&program)` per iteration,
//     which constructs a fresh `CodeBuffer` and consumes the AST. This is
//     the exact pattern Kessel uses (`codegen_init` + `codegen_program` +
//     `codegen_destroy` per iter).
//   * One warm-up iteration is untimed to prime the dispatch tables.
//   * Stats reported: mean / min / max / P50 / P95 / P99 in microseconds,
//     matching the existing OXC parser microbench output shape so
//     `bench_vs_oxc.sh` can reuse the same line parser.
use std::{env, fs, path::Path, process, time::Instant};

use oxc_allocator::Allocator;
use oxc_codegen::Codegen;
use oxc_parser::Parser;
use oxc_span::SourceType;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: oxc_codegen_microbench <file> <iterations>");
        process::exit(1);
    }
    let file_path = &args[1];
    let iters: usize = args[2].parse().expect("iters must be integer");
    let source = fs::read_to_string(file_path).expect("read file");
    let source_type = SourceType::from_path(Path::new(file_path)).unwrap_or_default();

    // Parse once. The AST lives in this allocator for the entire bench;
    // only the codegen pass is timed below.
    let allocator = Allocator::default();
    let parser_ret = Parser::new(&allocator, &source, source_type).parse();
    if !parser_ret.errors.is_empty() {
        eprintln!("oxc_codegen_microbench: parse failed for {}", file_path);
        for e in &parser_ret.errors {
            eprintln!("  {}", e);
        }
        process::exit(1);
    }
    let program = parser_ret.program;

    // Warm-up (not timed). Matches the Kessel harness's untimed warm-up.
    let warm = Codegen::new().build(&program);
    std::hint::black_box(&warm);

    let mut durations: Vec<u128> = Vec::with_capacity(iters);
    let mut output_bytes_last: usize = 0;
    for _ in 0..iters {
        let start = Instant::now();
        let ret = Codegen::new().build(&program);
        let elapsed = start.elapsed().as_nanos();
        output_bytes_last = ret.code.len();
        std::hint::black_box(ret);
        durations.push(elapsed);
    }
    durations.sort();
    let sum: u128 = durations.iter().sum();
    let mean = sum / iters as u128;
    let min = durations[0];
    let max = durations[iters - 1];
    let p50 = durations[iters / 2];
    let p95 = durations[(iters as f64 * 0.95) as usize];
    let p99 = durations[(iters as f64 * 0.99) as usize];

    println!(
        "Microbench: {} ({} bytes in, {} bytes out)",
        file_path,
        source.len(),
        output_bytes_last
    );
    println!("Iterations: {}", iters);
    println!("Total time:  {:.2} ms", sum as f64 / 1_000_000.0);
    println!("Mean:        {:.3} us", mean as f64 / 1000.0);
    println!("Min:         {:.3} us", min as f64 / 1000.0);
    println!("Max:         {:.3} us", max as f64 / 1000.0);
    println!("P50:         {:.3} us", p50 as f64 / 1000.0);
    println!("P95:         {:.3} us", p95 as f64 / 1000.0);
    println!("P99:         {:.3} us", p99 as f64 / 1000.0);
}
