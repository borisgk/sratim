use serde::Deserialize;

#[derive(Deserialize, Debug)]
struct Params {
    path: String,
}

fn main() {
    let qs = "path=Movie's.mp4";
    let p: Params = serde_urlencoded::from_str(qs).unwrap();
    println!("{:?}", p);

    let qs2 = "path=Movie%27s.mp4";
    let p2: Params = serde_urlencoded::from_str(qs2).unwrap();
    println!("{:?}", p2);
}
