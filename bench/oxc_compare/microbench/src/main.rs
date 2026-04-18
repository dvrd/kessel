use std::{env, fs, path::Path, process, time::Instant};
use oxc_allocator::Allocator;
use oxc_parser::Parser;
use oxc_span::SourceType;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: oxc_microbench <file> <iterations>");
        process::exit(1);
    }
    let file_path = &args[1];
    let iters: usize = args[2].parse().expect("iters must be integer");
    let source = fs::read_to_string(file_path).expect("read file");
    let source_type = SourceType::from_path(Path::new(file_path)).unwrap_or_default();

    // Warmup (match Kessel methodology — 1 untimed run)
    {
        let allocator = Allocator::default();
        let _ = Parser::new(&allocator, &source, source_type).parse();
    }

    // Measured loop — each iteration creates/resets allocator (matches Kessel creating arena per iter)
    let mut durations: Vec<u128> = Vec::with_capacity(iters);
    for _ in 0..iters {
        let allocator = Allocator::default();
        let start = Instant::now();
        let ret = Parser::new(&allocator, &source, source_type).parse();
        // std::hint::black_box to prevent DCE
        std::hint::black_box(&ret);
        let elapsed = start.elapsed().as_nanos();
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

    println!("Microbench: {} ({} bytes)", file_path, source.len());
    println!("Iterations: {}", iters);
    println!("Total time:  {:.2} ms", sum as f64 / 1_000_000.0);
    println!("Mean:        {:.3} us", mean as f64 / 1000.0);
    println!("Min:         {:.3} us", min as f64 / 1000.0);
    println!("Max:         {:.3} us", max as f64 / 1000.0);
    println!("P50:         {:.3} us", p50 as f64 / 1000.0);
    println!("P95:         {:.3} us", p95 as f64 / 1000.0);
    println!("P99:         {:.3} us", p99 as f64 / 1000.0);
}
