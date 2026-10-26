use app_context_kit::{AppContext, Manifest, OpenOptions};
use serde_json::json;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest = Manifest::parse(&std::fs::read_to_string("app.json")?)?;

    AppContext::run(manifest, OpenOptions::default(), |ctx| {
        // A setting: kept in <config>/config.json, written atomically.
        let launches = ctx.config.get_or::<i64>("launches", 0) + 1;
        ctx.config.set("launches", json!(launches)).expect("settings are writable");

        // A file of the app's own: under <data>.
        std::fs::write(ctx.data_file("hello.txt"), format!("launch {launches}\n")).expect("data dir is writable");

        println!("app      {} {}", ctx.manifest.id, ctx.manifest.version);
        println!("mode     {}{}", ctx.mode().as_str(), if ctx.is_scratch() { " (scratch)" } else { "" });
        println!("data     {}", ctx.resolved.dirs.data);
        println!("config   {}", ctx.resolved.dirs.config);
        println!("launches {launches}");
        println!("venue    {}", ctx.venue.description());
    })?;
    Ok(())
}
