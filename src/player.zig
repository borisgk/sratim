const std = @import("std");

pub fn generatePlayerHtml(allocator: std.mem.Allocator, file_param: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, 
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>Shaka Player</title>
        \\  <!-- Shaka Player compiled library -->
        \\  <script src="/shaka/shaka-player.ui.js"></script>
        \\  <!-- Shaka Player UI compiled library default CSS -->
        \\  <link rel="stylesheet" href="/shaka/controls.css">
        \\</head>
        \\<body style="margin: 0; background-color: #000; height: 100vh; display: flex; align-items: center; justify-content: center;">
        \\  <div id="videoContainer" style="width: 100%; max-width: 1280px;">
        \\    <video id="video" style="width: 100%; height: 100%;"></video>
        \\  </div>
        \\  <script>
        \\    const manifestUri = '/manifest.mpd?file={s}';
        \\
        \\    async function init() {{
        \\      const video = document.getElementById('video');
        \\      const videoContainer = document.getElementById('videoContainer');
        \\      
        \\      const player = new shaka.Player();
        \\      await player.attach(video);
        \\
        \\      // Set up the UI
        \\      const ui = new shaka.ui.Overlay(player, videoContainer, video);
        \\      
        \\      try {{
        \\        await player.load(manifestUri);
        \\        console.log('The video has now been loaded!');
        \\      }} catch (e) {{
        \\        console.error('Error loading video', e);
        \\      }}
        \\    }}
        \\
        \\    document.addEventListener('shaka-ui-loaded', init);
        \\  </script>
        \\</body>
        \\</html>
    , .{file_param});
}
