fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let env = litenotch::Env::from_process();
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    let code = litenotch::run(
        &args,
        &env,
        &mut stdin.lock(),
        &mut stdout.lock(),
        &mut stderr.lock(),
    );
    std::process::exit(code);
}
