use std::{env, fs, path::Path, process};
use oxc_allocator::Allocator;
use oxc_parser::Parser;
use oxc_span::SourceType;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: oxc_cli_equiv <file>");
        process::exit(1);
    }
    let file_path = &args[1];
    let source = fs::read_to_string(file_path).expect("read file");
    let source_type = SourceType::from_path(Path::new(file_path)).unwrap_or_default();
    let allocator = Allocator::default();
    let ret = Parser::new(&allocator, &source, source_type).parse();

    // Emit full ESTree JSON (equivalent to what Kessel CLI does)
    let json = ret.program.to_estree_js_json(false);
    println!("{}", json);
    eprintln!("Parse errors: {}", ret.errors.len());
}
