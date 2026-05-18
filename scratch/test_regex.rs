fn main() {
    let file_name = "Tainstvennaja strast'.01.HDTVRip.(720p).GeneralFilm.mkv";
    let alt_ep_re = regex::Regex::new(r"[\._\s-]([0-9]{2,3})[\._\s-]").unwrap();
    if let Some(caps) = alt_ep_re.captures(file_name) {
        let ep = &caps[1];
        let show_name = &file_name[..caps.get(0).unwrap().start()];
        println!("ep: {}, show_name: {}", ep, show_name);
    } else {
        println!("No match");
    }
}
