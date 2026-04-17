use std::env;
use std::fs;
use std::time::Instant;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        println!("Usage: compare_oxc <file>");
        return;
    }
    
    let source = fs::read_to_string(&args[1]).unwrap();
    
    // Warmup
    let _ = source.len();
    
    // Benchmark
    let start = Instant::now();
    for _ in 0..10 {
        let _ = source.len(); // Simulate work
    }
    let elapsed = start.elapsed();
    
    println!("Rust baseline: {:?} for 10 iterations", elapsed / 10);
}
