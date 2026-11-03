const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 'magic' module
    const magic = b.createModule(.{
        .root_source_file = b.path("src/magic_numbers.zig"),
        .target = target,
        .optimize = optimize,
    });

    //| Options

    // Display width
    const cjk = b.option(bool, "cjk", "Ambiguous code points are wide (display width: 2)") orelse false;
    const dwp_options = b.addOptions();
    dwp_options.addOption(bool, "cjk", cjk);

    // Visible Controls
    const c0_width = b.option(
        i4,
        "c0_width",
        "C0 controls have this width (default: 0, <BS> <Del> default -1)",
    );
    dwp_options.addOption(?i4, "c0_width", c0_width);
    const c1_width = b.option(
        i4,
        "c1_width",
        "C1 controls have this width (default: 0)",
    );
    dwp_options.addOption(?i4, "c1_width", c1_width);

    //| Offset size
    const fat_offset = b.option(bool, "fat_offset", "Offsets in iterators and data structures will be u64") orelse false;
    const size_config = b.addOptions();
    size_config.addOption(bool, "fat_offset", fat_offset);

    //| Code generation

    // Grapheme break
    const gbp_gen_exe = b.addExecutable(.{
        .name = "gbp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/gbp.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    gbp_gen_exe.root_module.addAnonymousImport("DerivedCoreProperties.txt", .{ .root_source_file = b.path("data/unicode/DerivedCoreProperties.txt") });
    gbp_gen_exe.root_module.addAnonymousImport("GraphemeBreakProperty.txt", .{ .root_source_file = b.path("data/unicode/auxiliary/GraphemeBreakProperty.txt") });
    gbp_gen_exe.root_module.addAnonymousImport("emoji-data.txt", .{ .root_source_file = b.path("data/unicode/emoji/emoji-data.txt") });
    const run_gbp_gen_exe = b.addRunArtifact(gbp_gen_exe);
    const gbp_gen_out = run_gbp_gen_exe.addOutputFileArg("gbp.zig");

    // Emoji
    const emoji_gen_exe = b.addExecutable(.{
        .name = "emoji",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/emoji.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    emoji_gen_exe.root_module.addAnonymousImport("emoji-data.txt", .{ .root_source_file = b.path("data/unicode/emoji/emoji-data.txt") });
    const run_emoji_gen_exe = b.addRunArtifact(emoji_gen_exe);
    const emoji_gen_out = run_emoji_gen_exe.addOutputFileArg("emoji.zig");

    const wbp_gen_exe = b.addExecutable(.{
        .name = "wbp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/wbp.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    wbp_gen_exe.root_module.addAnonymousImport("WordBreakProperty.txt", .{ .root_source_file = b.path("data/unicode/auxiliary/WordBreakProperty.txt") });
    const run_wbp_gen_exe = b.addRunArtifact(wbp_gen_exe);
    const wbp_gen_out = run_wbp_gen_exe.addOutputFileArg("wbp.zig");

    const dwp_gen_exe = b.addExecutable(.{
        .name = "dwp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/dwp.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    dwp_gen_exe.root_module.addAnonymousImport("DerivedEastAsianWidth.txt", .{ .root_source_file = b.path("data/unicode/extracted/DerivedEastAsianWidth.txt") });
    dwp_gen_exe.root_module.addAnonymousImport("DerivedGeneralCategory.txt", .{ .root_source_file = b.path("data/unicode/extracted/DerivedGeneralCategory.txt") });
    dwp_gen_exe.root_module.addOptions("options", dwp_options);
    const run_dwp_gen_exe = b.addRunArtifact(dwp_gen_exe);
    const dwp_gen_out = run_dwp_gen_exe.addOutputFileArg("dwp.zig");

    // Normalization properties
    const canon_gen_exe = b.addExecutable(.{
        .name = "canon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/canon.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    canon_gen_exe.root_module.addAnonymousImport("UnicodeData.txt", .{ .root_source_file = b.path("data/unicode/UnicodeData.txt") });
    const run_canon_gen_exe = b.addRunArtifact(canon_gen_exe);
    const canon_gen_out = run_canon_gen_exe.addOutputFileArg("canon.zig");

    const compat_gen_exe = b.addExecutable(.{
        .name = "compat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/compat.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    compat_gen_exe.root_module.addAnonymousImport("UnicodeData.txt", .{ .root_source_file = b.path("data/unicode/UnicodeData.txt") });
    const run_compat_gen_exe = b.addRunArtifact(compat_gen_exe);
    const compat_gen_out = run_compat_gen_exe.addOutputFileArg("compat.zig");

    const hangul_gen_exe = b.addExecutable(.{
        .name = "hangul",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/hangul.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    hangul_gen_exe.root_module.addAnonymousImport("HangulSyllableType.txt", .{ .root_source_file = b.path("data/unicode/HangulSyllableType.txt") });
    const run_hangul_gen_exe = b.addRunArtifact(hangul_gen_exe);
    const hangul_gen_out = run_hangul_gen_exe.addOutputFileArg("hangul.zig");

    const normp_gen_exe = b.addExecutable(.{
        .name = "normp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/normp.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    normp_gen_exe.root_module.addAnonymousImport("DerivedNormalizationProps.txt", .{ .root_source_file = b.path("data/unicode/DerivedNormalizationProps.txt") });
    const run_normp_gen_exe = b.addRunArtifact(normp_gen_exe);
    const normp_gen_out = run_normp_gen_exe.addOutputFileArg("normp.zig");

    const ccc_gen_exe = b.addExecutable(.{
        .name = "ccc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/ccc.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    ccc_gen_exe.root_module.addAnonymousImport("DerivedCombiningClass.txt", .{ .root_source_file = b.path("data/unicode/extracted/DerivedCombiningClass.txt") });
    const run_ccc_gen_exe = b.addRunArtifact(ccc_gen_exe);
    const ccc_gen_out = run_ccc_gen_exe.addOutputFileArg("ccc.zig");

    const qc_gen_exe = b.addExecutable(.{
        .name = "quickcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/norm_qc.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    qc_gen_exe.root_module.addAnonymousImport("DerivedNormalizationProps.txt", .{ .root_source_file = b.path("data/unicode/DerivedNormalizationProps.txt") });
    const run_qc_gen_exe = b.addRunArtifact(qc_gen_exe);
    const qc_gen_out = run_qc_gen_exe.addOutputFileArg("quickcheck.zig");

    const gencat_gen_exe = b.addExecutable(.{
        .name = "gencat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/gencat.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    gencat_gen_exe.root_module.addAnonymousImport("DerivedGeneralCategory.txt", .{ .root_source_file = b.path("data/unicode/extracted/DerivedGeneralCategory.txt") });
    const run_gencat_gen_exe = b.addRunArtifact(gencat_gen_exe);
    const gencat_gen_out = run_gencat_gen_exe.addOutputFileArg("gencat.zig");

    const fold_gen_exe = b.addExecutable(.{
        .name = "fold",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/fold.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    fold_gen_exe.root_module.addAnonymousImport("DerivedCoreProperties.txt", .{ .root_source_file = b.path("data/unicode/DerivedCoreProperties.txt") });
    fold_gen_exe.root_module.addAnonymousImport("CaseFolding.txt", .{ .root_source_file = b.path("data/unicode/CaseFolding.txt") });
    const run_fold_gen_exe = b.addRunArtifact(fold_gen_exe);
    const fold_gen_out = run_fold_gen_exe.addOutputFileArg("fold.zig");

    const caseless_gen_exe = b.addExecutable(.{
        .name = "caseless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/caseless.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    caseless_gen_exe.root_module.addAnonymousImport("UnicodeData.txt", .{ .root_source_file = b.path("data/unicode/UnicodeData.txt") });
    const run_caseless_gen_exe = b.addRunArtifact(caseless_gen_exe);
    const caseless_gen_out = run_caseless_gen_exe.addOutputFileArg("caseless.zig");

    // Numeric types
    const num_gen_exe = b.addExecutable(.{
        .name = "numeric",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/numeric.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    num_gen_exe.root_module.addAnonymousImport("DerivedNumericType.txt", .{ .root_source_file = b.path("data/unicode/extracted/DerivedNumericType.txt") });
    const run_num_gen_exe = b.addRunArtifact(num_gen_exe);
    const num_gen_out = run_num_gen_exe.addOutputFileArg("numeric.zig");

    // Case mappings
    const case_gen_exe = b.addExecutable(.{
        .name = "case",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/case.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    case_gen_exe.root_module.addAnonymousImport("UnicodeData.txt", .{ .root_source_file = b.path("data/unicode/UnicodeData.txt") });
    case_gen_exe.root_module.addAnonymousImport("SpecialCasing.txt", .{ .root_source_file = b.path("data/unicode/SpecialCasing.txt") });
    case_gen_exe.root_module.addAnonymousImport("DerivedCoreProperties.txt", .{ .root_source_file = b.path("data/unicode/DerivedCoreProperties.txt") });

    const run_case_gen_exe = b.addRunArtifact(case_gen_exe);
    const case_gen_out = run_case_gen_exe.addOutputFileArg("case.zig");
    const scripts_gen_exe = b.addExecutable(.{
        .name = "scripts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/scripts.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    scripts_gen_exe.root_module.addAnonymousImport("Scripts.txt", .{ .root_source_file = b.path("data/unicode/Scripts.txt") });
    const run_scripts_gen_exe = b.addRunArtifact(scripts_gen_exe);
    const scripts_gen_out = run_scripts_gen_exe.addOutputFileArg("scripts.zig");

    const core_gen_exe = b.addExecutable(.{
        .name = "core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/core_props.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    core_gen_exe.root_module.addAnonymousImport("DerivedCoreProperties.txt", .{ .root_source_file = b.path("data/unicode/DerivedCoreProperties.txt") });
    const run_core_gen_exe = b.addRunArtifact(core_gen_exe);
    const core_gen_out = run_core_gen_exe.addOutputFileArg("core_props.zig");

    const props_gen_exe = b.addExecutable(.{
        .name = "props",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/props.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    props_gen_exe.root_module.addAnonymousImport("PropList.txt", .{ .root_source_file = b.path("data/unicode/PropList.txt") });
    const run_props_gen_exe = b.addRunArtifact(props_gen_exe);
    const props_gen_out = run_props_gen_exe.addOutputFileArg("props.zig");

    // Modules we provide

    // Code points
    const code_point = b.addModule("code_point", .{
        .root_source_file = b.path("src/code_point.zig"),
        .target = target,
        .optimize = optimize,
    });
    code_point.addOptions("config", size_config);

    const code_point_t = b.addTest(.{
        .name = "code_point",
        .root_module = code_point,
    });
    const code_point_tr = b.addRunArtifact(code_point_t);

    // Graphemes
    const graphemes = b.addModule("Graphemes", .{
        .root_source_file = b.path("src/Graphemes.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphemes.addAnonymousImport("gbp", .{ .root_source_file = gbp_gen_out });
    graphemes.addImport("code_point", code_point);
    graphemes.addOptions("config", size_config);

    const grapheme_t = b.addTest(.{
        .name = "Graphemes",
        .root_module = graphemes,
    });
    const grapheme_tr = b.addRunArtifact(grapheme_t);

    // Emoji module
    const emoji = b.addModule("Emoji", .{
        .root_source_file = b.path("src/Emoji.zig"),
        .target = target,
        .optimize = optimize,
    });
    emoji.addAnonymousImport("emoji", .{ .root_source_file = emoji_gen_out });

    const emoji_t = b.addTest(.{
        .name = "Emoji",
        .root_module = emoji,
    });
    const emoji_tr = b.addRunArtifact(emoji_t);

    // Word Breaking
    const words = b.addModule("Words", .{
        .root_source_file = b.path("src/Words.zig"),
        .target = target,
        .optimize = optimize,
    });
    words.addAnonymousImport("wbp", .{ .root_source_file = wbp_gen_out });
    words.addImport("code_point", code_point);

    const words_t = b.addTest(.{
        .name = "WordBreak",
        .root_module = words,
    });
    const words_tr = b.addRunArtifact(words_t);

    // ASCII utilities
    const ascii = b.addModule("ascii", .{
        .root_source_file = b.path("src/ascii.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ascii_t = b.addTest(.{
        .name = "ascii",
        .root_module = ascii,
    });
    const ascii_tr = b.addRunArtifact(ascii_t);

    // Fixed pitch font display width
    const display_width = b.addModule("DisplayWidth", .{
        .root_source_file = b.path("src/DisplayWidth.zig"),
        .target = target,
        .optimize = optimize,
    });
    display_width.addAnonymousImport("dwp", .{ .root_source_file = dwp_gen_out });
    display_width.addImport("ascii", ascii);
    display_width.addImport("code_point", code_point);
    display_width.addImport("Graphemes", graphemes);
    display_width.addOptions("options", dwp_options); // For testing
    graphemes.addImport("DisplayWidth", display_width);

    const display_width_t = b.addTest(.{
        .name = "display_width",
        .root_module = display_width,
    });
    const display_width_tr = b.addRunArtifact(display_width_t);

    // Normalization
    const ccc_data = b.createModule(.{
        .root_source_file = b.path("src/CombiningData.zig"),
        .target = target,
        .optimize = optimize,
    });
    ccc_data.addAnonymousImport("ccc", .{ .root_source_file = ccc_gen_out });

    const ccc_data_t = b.addTest(.{
        .name = "ccc_data",
        .root_module = ccc_data,
    });
    const ccc_data_tr = b.addRunArtifact(ccc_data_t);

    const canon_data = b.createModule(.{
        .root_source_file = b.path("src/CanonData.zig"),
        .target = target,
        .optimize = optimize,
    });
    canon_data.addAnonymousImport("canon", .{ .root_source_file = canon_gen_out });
    canon_data.addImport("magic", magic);

    const canon_data_t = b.addTest(.{
        .name = "canon_data",
        .root_module = canon_data,
    });
    const canon_data_tr = b.addRunArtifact(canon_data_t);

    const compat_data = b.createModule(.{
        .root_source_file = b.path("src/CompatData.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_data.addAnonymousImport("compat", .{ .root_source_file = compat_gen_out });
    compat_data.addImport("magic", magic);

    const compat_data_t = b.addTest(.{
        .name = "compat_data",
        .root_module = compat_data,
    });
    const compat_data_tr = b.addRunArtifact(compat_data_t);

    const hangul_data = b.createModule(.{
        .root_source_file = b.path("src/HangulData.zig"),
        .target = target,
        .optimize = optimize,
    });
    hangul_data.addAnonymousImport("hangul", .{ .root_source_file = hangul_gen_out });

    const hangul_data_t = b.addTest(.{
        .name = "hangul_data",
        .root_module = hangul_data,
    });
    const hangul_data_tr = b.addRunArtifact(hangul_data_t);

    const normp_data = b.createModule(.{
        .root_source_file = b.path("src/NormPropsData.zig"),
        .target = target,
        .optimize = optimize,
    });
    normp_data.addAnonymousImport("normp", .{ .root_source_file = normp_gen_out });

    const normp_data_t = b.addTest(.{
        .name = "normp_data",
        .root_module = normp_data,
    });
    const normp_data_tr = b.addRunArtifact(normp_data_t);

    const norm_qc_data = b.createModule(.{
        .root_source_file = b.path("src/NormQuickCheckData.zig"),
        .target = target,
        .optimize = optimize,
    });
    norm_qc_data.addAnonymousImport("quickcheck", .{ .root_source_file = qc_gen_out });

    const norm_qc_data_t = b.addTest(.{
        .name = "norm_qc_data",
        .root_module = norm_qc_data,
    });
    const norm_qc_data_tr = b.addRunArtifact(norm_qc_data_t);

    const norm = b.addModule("Normalize", .{
        .root_source_file = b.path("src/Normalize.zig"),
        .target = target,
        .optimize = optimize,
    });
    norm.addImport("ascii", ascii);
    norm.addImport("code_point", code_point);
    norm.addImport("CanonData", canon_data);
    norm.addImport("CombiningData", ccc_data);
    norm.addImport("CompatData", compat_data);
    norm.addImport("HangulData", hangul_data);
    norm.addImport("NormPropsData", normp_data);
    norm.addImport("NormQuickCheckData", norm_qc_data);

    const norm_t = b.addTest(.{
        .name = "norm",
        .root_module = norm,
    });
    const norm_tr = b.addRunArtifact(norm_t);

    // General Category
    const gencat = b.addModule("GeneralCategories", .{
        .root_source_file = b.path("src/GeneralCategories.zig"),
        .target = target,
        .optimize = optimize,
    });
    gencat.addAnonymousImport("gencat", .{ .root_source_file = gencat_gen_out });

    const gencat_t = b.addTest(.{
        .name = "gencat",
        .root_module = gencat,
    });
    const gencat_tr = b.addRunArtifact(gencat_t);

    // Case folding
    const case_fold = b.addModule("CaseFolding", .{
        .root_source_file = b.path("src/CaseFolding.zig"),
        .target = target,
        .optimize = optimize,
    });
    case_fold.addAnonymousImport("fold", .{ .root_source_file = fold_gen_out });

    const case_fold_t = b.addTest(.{
        .name = "case_fold",
        .root_module = case_fold,
    });
    const case_fold_tr = b.addRunArtifact(case_fold_t);

    const caseless_match_data = b.addModule("CaselessMatchData", .{
        .root_source_file = b.path("src/CaselessMatchData.zig"),
        .target = target,
        .optimize = optimize,
    });
    caseless_match_data.addAnonymousImport("caseless", .{ .root_source_file = caseless_gen_out });

    const caseless_match_data_t = b.addTest(.{
        .name = "caseless_match_data",
        .root_module = caseless_match_data,
    });
    const caseless_match_data_tr = b.addRunArtifact(caseless_match_data_t);

    const caseless_match = b.addModule("CaselessMatch", .{
        .root_source_file = b.path("src/CaselessMatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    caseless_match.addImport("ascii", ascii);
    caseless_match.addImport("code_point", code_point);
    caseless_match.addImport("CanonData", canon_data);
    caseless_match.addImport("CaselessMatchData", caseless_match_data);
    caseless_match.addImport("CaseFolding", case_fold);
    caseless_match.addImport("CombiningData", ccc_data);
    caseless_match.addImport("CompatData", compat_data);
    caseless_match.addImport("HangulData", hangul_data);
    caseless_match.addImport("NormQuickCheckData", norm_qc_data);
    caseless_match.addImport("NormPropsData", normp_data);

    const caseless_match_t = b.addTest(.{
        .name = "caseless_match",
        .root_module = caseless_match,
    });
    const caseless_match_tr = b.addRunArtifact(caseless_match_t);

    // Letter case
    const letter_case = b.addModule("LetterCasing", .{
        .root_source_file = b.path("src/LetterCasing.zig"),
        .target = target,
        .optimize = optimize,
    });
    letter_case.addImport("code_point", code_point);
    letter_case.addAnonymousImport("case", .{ .root_source_file = case_gen_out });

    words.addImport("LetterCasing", letter_case);

    const letter_case_t = b.addTest(.{
        .name = "lettercase",
        .root_module = letter_case,
    });
    const letter_case_tr = b.addRunArtifact(letter_case_t);

    // Scripts
    const scripts = b.addModule("Scripts", .{
        .root_source_file = b.path("src/Scripts.zig"),
        .target = target,
        .optimize = optimize,
    });
    scripts.addAnonymousImport("script", .{ .root_source_file = scripts_gen_out });

    const scripts_t = b.addTest(.{
        .name = "scripts",
        .root_module = scripts,
    });
    const scripts_tr = b.addRunArtifact(scripts_t);

    // Properties
    const properties = b.addModule("Properties", .{
        .root_source_file = b.path("src/Properties.zig"),
        .target = target,
        .optimize = optimize,
    });
    properties.addAnonymousImport("core_props", .{ .root_source_file = core_gen_out });
    properties.addAnonymousImport("props", .{ .root_source_file = props_gen_out });
    properties.addAnonymousImport("numeric", .{ .root_source_file = num_gen_out });

    const zg_module = b.addModule("zg", .{
        .root_source_file = b.path("src/zg.zig"),
        .target = target,
        .optimize = optimize,
    });
    zg_module.addImport("ascii", ascii);
    zg_module.addImport("CaselessMatch", caseless_match);
    zg_module.addImport("CaseFolding", case_fold);
    zg_module.addImport("code_point", code_point);
    zg_module.addImport("DisplawWidth", display_width);
    zg_module.addImport("Emoji", emoji);
    zg_module.addImport("GeneralCategories", gencat);
    zg_module.addImport("Graphemes", graphemes);
    zg_module.addImport("LetterCasing", letter_case);
    zg_module.addImport("Normalize", norm);
    zg_module.addImport("Properties", properties);
    zg_module.addImport("Scripts", scripts);
    zg_module.addImport("Words", words);

    const properties_t = b.addTest(.{
        .name = "properties",
        .root_module = properties,
    });
    const properties_tr = b.addRunArtifact(properties_t);

    // Unicode Tests
    const unicode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unicode_tests.root_module.addAnonymousImport("GraphemeBreakTest.txt", .{ .root_source_file = b.path("data/unicode/auxiliary/GraphemeBreakTest.txt") });
    unicode_tests.root_module.addAnonymousImport("NormalizationTest.txt", .{ .root_source_file = b.path("data/unicode/NormalizationTest.txt") });
    unicode_tests.root_module.addAnonymousImport("WordBreakTest.txt", .{ .root_source_file = b.path("data/unicode/auxiliary/WordBreakTest.txt") });
    unicode_tests.root_module.addImport("CaselessMatch", caseless_match);
    unicode_tests.root_module.addImport("Graphemes", graphemes);
    unicode_tests.root_module.addImport("Normalize", norm);
    unicode_tests.root_module.addImport("Words", words);

    const run_unicode_tests = b.addRunArtifact(unicode_tests);

    const test_step = b.step("test", "Run all module tests");
    test_step.dependOn(&run_unicode_tests.step);
    test_step.dependOn(&code_point_tr.step);
    test_step.dependOn(&display_width_tr.step);
    test_step.dependOn(&grapheme_tr.step);
    test_step.dependOn(&emoji_tr.step);
    test_step.dependOn(&words_tr.step);
    test_step.dependOn(&ascii_tr.step);
    test_step.dependOn(&ccc_data_tr.step);
    test_step.dependOn(&canon_data_tr.step);
    test_step.dependOn(&compat_data_tr.step);
    test_step.dependOn(&hangul_data_tr.step);
    test_step.dependOn(&normp_data_tr.step);
    test_step.dependOn(&norm_qc_data_tr.step);
    test_step.dependOn(&norm_tr.step);
    test_step.dependOn(&gencat_tr.step);
    test_step.dependOn(&case_fold_tr.step);
    test_step.dependOn(&caseless_match_data_tr.step);
    test_step.dependOn(&caseless_match_tr.step);
    test_step.dependOn(&letter_case_tr.step);
    test_step.dependOn(&scripts_tr.step);
    test_step.dependOn(&properties_tr.step);
}
