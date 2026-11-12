//! Entry point of the Linux Builder frontend.

use clap::Parser;

use builder_linux::cli::{self, Cli};

fn main() {
    let cli = Cli::parse();
    std::process::exit(cli::run(cli));
}
