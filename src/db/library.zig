const std = @import("std");
const db_mod = @import("db.zig");
pub const schema = @import("../storage/schema.zig");

pub const LibraryType = schema.LibraryType;
pub const Library = schema.Library;

/// Inserts a new library folder config into the storage engine.
pub fn addLibrary(database: *db_mod.Database, name: []const u8, path: []const u8, lib_type: LibraryType) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    _ = try cat.addLibrary(name, path, lib_type);
    cat.snapshot() catch {};
}

/// Retrieves all libraries from the storage engine.
pub fn getLibraries(database: *db_mod.Database, allocator: std.mem.Allocator) ![]Library {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    return cat.getLibraries(allocator);
}

/// Retrieves a single library configuration by its ID.
pub fn getLibraryById(database: *db_mod.Database, allocator: std.mem.Allocator, id: i64) !?Library {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    return cat.getLibraryById(allocator, id);
}
