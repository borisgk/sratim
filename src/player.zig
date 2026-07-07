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
        \\      // Pre-buffer more chunks in advance
        \\      player.configure({{
        \\        streaming: {{
        \\          bufferingGoal: 600,     // Buffer up to 10 minutes (600s) ahead. Note: May hit browser memory limits on high bitrates!
        \\          rebufferingGoal: 10,    // Wait for 10 seconds of buffer before resuming playback
        \\          bufferBehind: 30        // Keep 30 seconds of history to allow quick seeking backwards
        \\        }}
        \\      }});
        \\
        \\      // Set up the UI
        \\      const ui = new shaka.ui.Overlay(player, videoContainer, video);
        \\
        \\      // Make the prebuffered amount distinctly visible on the progress bar
        \\      ui.configure({{
        \\        seekBarColors: {{
        \\          base: 'rgba(255, 255, 255, 0.2)',
        \\          buffered: 'rgba(0, 255, 170, 0.6)', // Bright neon cyan/green for buffered
        \\          played: '#FF0055' // Vibrant pink/red for played
        \\        }}
        \\      }});
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
