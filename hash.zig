// hash.zig
// Encept: Perceptual hash extraction from H.264 encoding decisions

const std = @import("std");
const bitstream = @import("bitstream.zig");
const h264 = @import("h264_parser.zig");
const macroblock = @import("macroblock.zig");

// =============================================================================
// Encept Hash Structure
// =============================================================================

pub const EnceptHash = struct {
    // Dimensions
    width: u16,
    height: u16,
    width_mbs: u16,
    height_mbs: u16,

    // Per-macroblock data (compact)
    mb_types: []u8, // MbTypeCategory compressed
    intra_modes: []u8, // Packed prediction modes
    dc_luma: []i16, // Average DC per MB
    dc_cb: []i16,
    dc_cr: []i16,

    // Summary features (for fast screening)
    qp_avg: u8,
    skip_ratio: f16,
    intra_ratio: f16,
    dc_mean: i16,
    dc_std: f16,
    edge_density: f16,

    // Spatial pyramid (multi-scale features)
    pyramid_2x2: [4]i16, // 2x2 average DC
    pyramid_4x4: [16]i16, // 4x4 average DC

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width_mbs: u16, height_mbs: u16) !Self {
        const num_mbs = @as(usize, width_mbs) * height_mbs;
        return Self{
            .width = width_mbs * 16,
            .height = height_mbs * 16,
            .width_mbs = width_mbs,
            .height_mbs = height_mbs,
            .mb_types = try allocator.alloc(u8, num_mbs),
            .intra_modes = try allocator.alloc(u8, num_mbs),
            .dc_luma = try allocator.alloc(i16, num_mbs),
            .dc_cb = try allocator.alloc(i16, num_mbs),
            .dc_cr = try allocator.alloc(i16, num_mbs),
            .qp_avg = 0,
            .skip_ratio = 0,
            .intra_ratio = 0,
            .dc_mean = 0,
            .dc_std = 0,
            .edge_density = 0,
            .pyramid_2x2 = [_]i16{0} ** 4,
            .pyramid_4x4 = [_]i16{0} ** 16,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.mb_types);
        allocator.free(self.intra_modes);
        allocator.free(self.dc_luma);
        allocator.free(self.dc_cb);
        allocator.free(self.dc_cr);
    }

    // =========================================================================
    // Distance Metrics
    // =========================================================================

    /// Fast screening distance - O(1) using summary features
    /// Use to quickly filter candidates before full comparison
    pub fn distanceFast(self: *const Self, other: *const Self) f32 {
        // Different dimensions = infinite distance
        if (self.width_mbs != other.width_mbs or self.height_mbs != other.height_mbs) {
            return std.math.floatMax(f32);
        }

        var dist: f32 = 0;

        // QP difference (encoding quality)
        const qp_diff: f32 = @floatFromInt(@as(i16, self.qp_avg) - @as(i16, other.qp_avg));
        dist += @abs(qp_diff) * 0.5;

        // Skip ratio (motion/complexity)
        dist += @abs(@as(f32, self.skip_ratio) - @as(f32, other.skip_ratio)) * 50.0;

        // Intra ratio (scene type)
        dist += @abs(@as(f32, self.intra_ratio) - @as(f32, other.intra_ratio)) * 30.0;

        // DC mean (brightness)
        const dc_diff: f32 = @floatFromInt(@as(i32, self.dc_mean) - @as(i32, other.dc_mean));
        dist += @abs(dc_diff) * 0.1;

        // DC std (contrast)
        dist += @abs(@as(f32, self.dc_std) - @as(f32, other.dc_std)) * 0.5;

        // Edge density (texture)
        dist += @abs(@as(f32, self.edge_density) - @as(f32, other.edge_density)) * 20.0;

        return dist;
    }

    /// Spatial pyramid distance - O(20) comparing multi-scale features
    /// Good balance of speed and accuracy
    pub fn distancePyramid(self: *const Self, other: *const Self) f32 {
        if (self.width_mbs != other.width_mbs or self.height_mbs != other.height_mbs) {
            return std.math.floatMax(f32);
        }

        var dist: f32 = 0;

        // 2x2 level (coarse structure)
        for (0..4) |i| {
            const diff: f32 = @floatFromInt(@as(i32, self.pyramid_2x2[i]) - @as(i32, other.pyramid_2x2[i]));
            dist += diff * diff;
        }
        dist = @sqrt(dist) * 2.0; // Weight coarse structure more

        // 4x4 level (medium structure)
        var dist_4x4: f32 = 0;
        for (0..16) |i| {
            const diff: f32 = @floatFromInt(@as(i32, self.pyramid_4x4[i]) - @as(i32, other.pyramid_4x4[i]));
            dist_4x4 += diff * diff;
        }
        dist += @sqrt(dist_4x4);

        return dist;
    }

    /// Full distance - O(num_mbs) comparing all macroblock data
    /// Most accurate but slowest
    pub fn distanceFull(self: *const Self, other: *const Self) f32 {
        if (self.width_mbs != other.width_mbs or self.height_mbs != other.height_mbs) {
            return std.math.floatMax(f32);
        }

        const num_mbs = self.dc_luma.len;
        var type_dist: f32 = 0;
        var dc_dist: f32 = 0;
        var mode_dist: f32 = 0;

        for (0..num_mbs) |i| {
            // MB type difference
            if (self.mb_types[i] != other.mb_types[i]) {
                type_dist += 1.0;
            }

            // DC coefficient difference (most important)
            const luma_diff: f32 = @floatFromInt(@as(i32, self.dc_luma[i]) - @as(i32, other.dc_luma[i]));
            const cb_diff: f32 = @floatFromInt(@as(i32, self.dc_cb[i]) - @as(i32, other.dc_cb[i]));
            const cr_diff: f32 = @floatFromInt(@as(i32, self.dc_cr[i]) - @as(i32, other.dc_cr[i]));
            dc_dist += @abs(luma_diff) + @abs(cb_diff) * 0.5 + @abs(cr_diff) * 0.5;

            // Intra mode difference
            if (self.intra_modes[i] != other.intra_modes[i]) {
                mode_dist += 1.0;
            }
        }

        const num_mbs_f: f32 = @floatFromInt(num_mbs);
        return (type_dist / num_mbs_f) * 100.0 +
            (dc_dist / num_mbs_f) * 0.5 +
            (mode_dist / num_mbs_f) * 20.0;
    }

    /// Cosine similarity on DC coefficients
    /// Robust to brightness/contrast changes
    pub fn cosineSimilarity(self: *const Self, other: *const Self) f32 {
        if (self.dc_luma.len != other.dc_luma.len) return 0;

        var dot: f64 = 0;
        var mag_a: f64 = 0;
        var mag_b: f64 = 0;

        for (self.dc_luma, other.dc_luma) |a, b| {
            const fa: f64 = @floatFromInt(a);
            const fb: f64 = @floatFromInt(b);
            dot += fa * fb;
            mag_a += fa * fa;
            mag_b += fb * fb;
        }

        if (mag_a == 0 or mag_b == 0) return 0;
        return @floatCast(dot / (@sqrt(mag_a) * @sqrt(mag_b)));
    }

    /// Hamming distance on binarized DC coefficients
    /// Very fast for large-scale search
    pub fn hammingDistance(self: *const Self, other: *const Self) u32 {
        if (self.dc_luma.len != other.dc_luma.len) return std.math.maxInt(u32);

        // Binarize: above median = 1, below = 0
        const median_a = self.dc_mean;
        const median_b = other.dc_mean;

        var hamming: u32 = 0;
        for (self.dc_luma, other.dc_luma) |a, b| {
            const bit_a: u1 = if (a > median_a) 1 else 0;
            const bit_b: u1 = if (b > median_b) 1 else 0;
            if (bit_a != bit_b) hamming += 1;
        }

        return hamming;
    }

    // =========================================================================
    // Serialization
    // =========================================================================

    pub fn serialize(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        const num_mbs = self.dc_luma.len;

        // Header: 32 bytes
        // Data: num_mbs * (1 + 1 + 2 + 2 + 2) = num_mbs * 8 bytes
        const header_size = 32;
        const data_size = num_mbs * 8;
        const pyramid_size = 4 * 2 + 16 * 2; // 2x2 + 4x4

        var buffer = try allocator.alloc(u8, header_size + data_size + pyramid_size);
        var offset: usize = 0;

        // Header
        std.mem.writeInt(u16, buffer[offset..][0..2], self.width, .little);
        offset += 2;
        std.mem.writeInt(u16, buffer[offset..][0..2], self.height, .little);
        offset += 2;
        std.mem.writeInt(u16, buffer[offset..][0..2], self.width_mbs, .little);
        offset += 2;
        std.mem.writeInt(u16, buffer[offset..][0..2], self.height_mbs, .little);
        offset += 2;
        buffer[offset] = self.qp_avg;
        offset += 1;
        std.mem.writeInt(u16, buffer[offset..][0..2], @bitCast(self.skip_ratio), .little);
        offset += 2;
        std.mem.writeInt(u16, buffer[offset..][0..2], @bitCast(self.intra_ratio), .little);
        offset += 2;
        std.mem.writeInt(i16, buffer[offset..][0..2], self.dc_mean, .little);
        offset += 2;
        std.mem.writeInt(u16, buffer[offset..][0..2], @bitCast(self.dc_std), .little);
        offset += 2;
        std.mem.writeInt(u16, buffer[offset..][0..2], @bitCast(self.edge_density), .little);
        offset += 2;

        // Padding to 32
        offset = 32;

        // MB types
        @memcpy(buffer[offset..][0..num_mbs], self.mb_types);
        offset += num_mbs;

        // Intra modes
        @memcpy(buffer[offset..][0..num_mbs], self.intra_modes);
        offset += num_mbs;

        // DC coefficients
        @memcpy(buffer[offset..][0 .. num_mbs * 2], std.mem.sliceAsBytes(self.dc_luma));
        offset += num_mbs * 2;
        @memcpy(buffer[offset..][0 .. num_mbs * 2], std.mem.sliceAsBytes(self.dc_cb));
        offset += num_mbs * 2;
        @memcpy(buffer[offset..][0 .. num_mbs * 2], std.mem.sliceAsBytes(self.dc_cr));
        offset += num_mbs * 2;

        // Pyramid
        @memcpy(buffer[offset..][0..8], std.mem.sliceAsBytes(&self.pyramid_2x2));
        offset += 8;
        @memcpy(buffer[offset..][0..32], std.mem.sliceAsBytes(&self.pyramid_4x4));

        return buffer;
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 32) return error.InvalidData;

        var offset: usize = 0;

        const width = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;
        const height = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;
        const width_mbs = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;
        const height_mbs = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;

        var hash = try Self.init(allocator, width_mbs, height_mbs);
        hash.width = width;
        hash.height = height;

        hash.qp_avg = data[offset];
        offset += 1;
        hash.skip_ratio = @bitCast(std.mem.readInt(u16, data[offset..][0..2], .little));
        offset += 2;
        hash.intra_ratio = @bitCast(std.mem.readInt(u16, data[offset..][0..2], .little));
        offset += 2;
        hash.dc_mean = std.mem.readInt(i16, data[offset..][0..2], .little);
        offset += 2;
        hash.dc_std = @bitCast(std.mem.readInt(u16, data[offset..][0..2], .little));
        offset += 2;
        hash.edge_density = @bitCast(std.mem.readInt(u16, data[offset..][0..2], .little));
        offset += 2;

        offset = 32;
        const num_mbs = hash.dc_luma.len;

        @memcpy(hash.mb_types, data[offset..][0..num_mbs]);
        offset += num_mbs;
        @memcpy(hash.intra_modes, data[offset..][0..num_mbs]);
        offset += num_mbs;

        @memcpy(std.mem.sliceAsBytes(hash.dc_luma), data[offset..][0 .. num_mbs * 2]);
        offset += num_mbs * 2;
        @memcpy(std.mem.sliceAsBytes(hash.dc_cb), data[offset..][0 .. num_mbs * 2]);
        offset += num_mbs * 2;
        @memcpy(std.mem.sliceAsBytes(hash.dc_cr), data[offset..][0 .. num_mbs * 2]);
        offset += num_mbs * 2;

        @memcpy(std.mem.sliceAsBytes(&hash.pyramid_2x2), data[offset..][0..8]);
        offset += 8;
        @memcpy(std.mem.sliceAsBytes(&hash.pyramid_4x4), data[offset..][0..32]);

        return hash;
    }

    pub fn byteSize(self: *const Self) usize {
        const num_mbs = self.dc_luma.len;
        return 32 + num_mbs * 8 + 8 + 32;
    }

    // =========================================================================
    // Compute Summary Features
    // =========================================================================

    pub fn computeSummary(self: *Self) void {
        const num_mbs = self.dc_luma.len;
        if (num_mbs == 0) return;

        // Count skip and intra MBs
        var skip_count: u32 = 0;
        var intra_count: u32 = 0;
        var qp_sum: u32 = 0;

        for (self.mb_types) |t| {
            // Simplified categorization
            if (t == 37 or t == 87) skip_count += 1; // P_Skip or B_Skip
            if (t <= 25) intra_count += 1; // Intra types
            qp_sum += self.qp_avg;
        }

        const n: f32 = @floatFromInt(num_mbs);
        self.skip_ratio = @floatCast(@as(f32, @floatFromInt(skip_count)) / n);
        self.intra_ratio = @floatCast(@as(f32, @floatFromInt(intra_count)) / n);

        // DC statistics
        var dc_sum: i64 = 0;
        for (self.dc_luma) |dc| {
            dc_sum += dc;
        }
        self.dc_mean = @intCast(@divTrunc(dc_sum, @as(i64, @intCast(num_mbs))));

        var variance: f64 = 0;
        for (self.dc_luma) |dc| {
            const diff: f64 = @floatFromInt(@as(i32, dc) - @as(i32, self.dc_mean));
            variance += diff * diff;
        }
        self.dc_std = @floatCast(@sqrt(variance / @as(f64, n)));

        // Edge density from intra mode diversity
        var edge_count: u32 = 0;
        for (self.intra_modes) |mode| {
            // Directional modes (not DC) indicate edges
            if (mode != 2 and mode != 0) edge_count += 1;
        }
        self.edge_density = @floatCast(@as(f32, @floatFromInt(edge_count)) / n);

        // Compute spatial pyramid
        self.computePyramid();
    }

    fn computePyramid(self: *Self) void {
        const w = self.width_mbs;
        const h = self.height_mbs;
        if (w == 0 or h == 0) return;

        // 2x2 pyramid
        const half_w = w / 2;
        const half_h = h / 2;

        for (0..2) |py| {
            for (0..2) |px| {
                var sum: i64 = 0;
                var count: u32 = 0;

                const start_x = px * half_w;
                const end_x = @min((px + 1) * half_w, w);
                const start_y = py * half_h;
                const end_y = @min((py + 1) * half_h, h);

                var y = start_y;
                while (y < end_y) : (y += 1) {
                    var x = start_x;
                    while (x < end_x) : (x += 1) {
                        sum += self.dc_luma[y * w + x];
                        count += 1;
                    }
                }

                if (count > 0) {
                    self.pyramid_2x2[py * 2 + px] = @intCast(@divTrunc(sum, count));
                }
            }
        }

        // 4x4 pyramid
        const quarter_w = w / 4;
        const quarter_h = h / 4;

        for (0..4) |py| {
            for (0..4) |px| {
                var sum: i64 = 0;
                var count: u32 = 0;

                const start_x = px * quarter_w;
                const end_x = @min((px + 1) * quarter_w, w);
                const start_y = py * quarter_h;
                const end_y = @min((py + 1) * quarter_h, h);

                var y = start_y;
                while (y < end_y) : (y += 1) {
                    var x = start_x;
                    while (x < end_x) : (x += 1) {
                        sum += self.dc_luma[y * w + x];
                        count += 1;
                    }
                }

                if (count > 0) {
                    self.pyramid_4x4[py * 4 + px] = @intCast(@divTrunc(sum, count));
                }
            }
        }
    }
};

// =============================================================================
// Hash Extractor
// =============================================================================

pub const HashExtractor = struct {
    allocator: std.mem.Allocator,
    parser: h264.H264Parser,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .parser = h264.H264Parser.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.parser.deinit();
    }

    /// Extract perceptual hash from H.264 bitstream
    pub fn extract(self: *Self, h264_data: []const u8) !EnceptHash {
        // Find NAL units
        var nal_units = try bitstream.findNalUnits(h264_data, self.allocator);
        defer nal_units.deinit();

        // Parse SPS and PPS first
        var sps: ?h264.SPS = null;
        var pps: ?h264.PPS = null;

        for (nal_units.items) |unit| {
            if (unit.isSPS()) {
                sps = try self.parser.parseSPS(unit.rbsp);
            } else if (unit.isPPS()) {
                pps = try self.parser.parsePPS(unit.rbsp);
            }
        }

        if (sps == null) return error.NoSPSFound;
        if (pps == null) return error.NoPPSFound;

        const s = sps.?;
        const p = pps.?;

        // Create hash structure
        var hash = try EnceptHash.init(
            self.allocator,
            @intCast(s.widthInMbs()),
            @intCast(s.heightInMbs()),
        );
        errdefer hash.deinit(self.allocator);

        // Initialize with defaults
        @memset(hash.mb_types, 0);
        @memset(hash.intra_modes, 2); // DC mode
        @memset(hash.dc_luma, 0);
        @memset(hash.dc_cb, 0);
        @memset(hash.dc_cr, 0);

        // Parse slices
        var total_qp: u32 = 0;
        var qp_count: u32 = 0;

        for (nal_units.items) |unit| {
            if (!unit.isSlice()) continue;

            const clean_rbsp = try bitstream.removeEmulationPrevention(unit.rbsp, self.allocator);
            defer self.allocator.free(clean_rbsp);

            const sh = try self.parser.parseSliceHeader(unit.rbsp, unit.nal_unit_type, unit.nal_ref_idc);
            const slice_qp = sh.sliceQP(p);
            total_qp += @intCast(@as(u32, @bitCast(slice_qp)));
            qp_count += 1;

            // Parse macroblocks
            var reader = bitstream.BitReader.init(clean_rbsp);

            // Skip to after slice header (simplified - needs proper parsing)
            const skip_bits = @min(reader.bitsRemaining(), 100);
            try reader.skipBits(skip_bits);

            var mb_parser = macroblock.MacroblockParser.init(self.allocator, s, p, sh);
            const num_mbs = @as(u32, s.widthInMbs()) * s.heightInMbs();

            var mb_addr: u32 = sh.first_mb_in_slice;
            while (mb_addr < num_mbs and reader.bitsRemaining() > 8) {
                // Check for skip run (P/B slices)
                var is_skip = false;
                if (!sh.slice_type.isIntra() and !p.entropy_coding_mode_flag) {
                    // CAVLC skip detection
                    const skip_run = reader.readUE() catch break;
                    if (skip_run > 0) {
                        // Skip macroblocks
                        for (0..skip_run) |_| {
                            if (mb_addr < num_mbs) {
                                hash.mb_types[mb_addr] = if (sh.slice_type.isBidirectional()) 87 else 37;
                                mb_addr += 1;
                            }
                        }
                        is_skip = (skip_run > 0);
                    }
                }

                if (mb_addr >= num_mbs) break;

                // Parse macroblock
                const mb = mb_parser.parseMacroblock(&reader, mb_addr, is_skip) catch break;

                // Store in hash
                hash.mb_types[mb_addr] = @intFromEnum(mb.mb_type_enum);
                hash.intra_modes[mb_addr] = @intFromEnum(mb.intra_16x16_pred_mode);
                hash.dc_luma[mb_addr] = mb.avgDCLuma();
                const chroma = mb.avgDCChroma();
                hash.dc_cb[mb_addr] = chroma.cb;
                hash.dc_cr[mb_addr] = chroma.cr;

                mb_addr += 1;
            }
        }

        // Set average QP
        hash.qp_avg = if (qp_count > 0) @intCast(total_qp / qp_count) else 26;

        // Compute summary features
        hash.computeSummary();

        return hash;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "EnceptHash init and summary" {
    const allocator = std.testing.allocator;

    var hash = try EnceptHash.init(allocator, 8, 6); // 128x96 image
    defer hash.deinit(allocator);

    // Fill with test data
    for (0..hash.dc_luma.len) |i| {
        hash.dc_luma[i] = @intCast(i * 10);
        hash.mb_types[i] = 1; // I_16x16
        hash.intra_modes[i] = 2; // DC
    }

    hash.computeSummary();

    try std.testing.expect(hash.dc_mean > 0);
    try std.testing.expect(hash.intra_ratio > 0);
}

test "EnceptHash serialization" {
    const allocator = std.testing.allocator;

    var hash = try EnceptHash.init(allocator, 4, 4);
    defer hash.deinit(allocator);

    hash.dc_mean = 100;
    hash.qp_avg = 28;

    const data = try hash.serialize(allocator);
    defer allocator.free(data);

    var hash2 = try EnceptHash.deserialize(allocator, data);
    defer hash2.deinit(allocator);

    try std.testing.expectEqual(hash.dc_mean, hash2.dc_mean);
    try std.testing.expectEqual(hash.qp_avg, hash2.qp_avg);
}

test "Distance metrics" {
    const allocator = std.testing.allocator;

    var hash1 = try EnceptHash.init(allocator, 4, 4);
    defer hash1.deinit(allocator);
    var hash2 = try EnceptHash.init(allocator, 4, 4);
    defer hash2.deinit(allocator);

    // Identical hashes
    @memset(hash1.dc_luma, 100);
    @memset(hash2.dc_luma, 100);
    hash1.computeSummary();
    hash2.computeSummary();

    try std.testing.expectEqual(@as(f32, 0), hash1.distanceFull(&hash2));
    try std.testing.expectEqual(@as(f32, 1.0), hash1.cosineSimilarity(&hash2));

    // Different hashes
    @memset(hash2.dc_luma, 200);
    hash2.computeSummary();

    try std.testing.expect(hash1.distanceFull(&hash2) > 0);
}
