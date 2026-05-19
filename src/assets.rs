use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "frontend/"]
pub struct Assets;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_assets_embedded() {
        let index = Assets::get("index.html");
        assert!(index.is_some(), "index.html should be embedded");
        
        let style = Assets::get("style.css");
        assert!(style.is_some(), "style.css should be embedded");

        let app = Assets::get("app.js");
        assert!(app.is_some(), "app.js should be embedded");
        
        let favicon = Assets::get("favicon.ico");
        assert!(favicon.is_some(), "favicon.ico should be embedded");
    }
}
