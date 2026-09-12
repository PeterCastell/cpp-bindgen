//! Zig declarations of the types in test/fixture.cpp, golden mangled names
//! from clang for both ABIs, and link tests through the target's mangling.
const std = @import("std");
const cpp = @import("root.zig");

const Signature = cpp.Signature;
const Template = cpp.Template;
const Kind = cpp.Kind;
const Ref = cpp.Ref;
const RRef = cpp.RRef;
const ConstPtr = cpp.ConstPtr;
const TParam = cpp.TParam;
const wchar_t = cpp.wchar_t;
const char16_t = cpp.char16_t;
const char32_t = cpp.char32_t;
const uchar = cpp.uchar;
const bindFn = cpp.bindFn;
const bindMethod = cpp.bindMethod;
const bindStatic = cpp.bindStatic;
const mangledName = cpp.mangledName;
const ClassAbi = cpp.ClassAbi;

const Counter = extern struct {
    n: c_int,
    pub const cpp_name = "ns::Counter";
};
const Vec2 = extern struct {
    x: c_int,
    y: c_int,
    pub const cpp_name = "ns::Vec2";
};

const Ops = extern struct {
    x: c_int,
    pub const cpp_name = "ns::Ops";
};

const Tpl = extern struct {
    n: c_int,
    pub const cpp_name = "ns::Tpl";
};

const Qualifier = enum(c_int) {
    lowp,
    highp,
    _,
    pub const cpp_name = "tpl::qualifier";
};
const TVec3 = extern struct {
    v: [3]f32,
    pub const cpp_template = Template{ .name = "tpl::vec", .args = &.{ .{ .int = 3 }, .{ .type = f32 }, .{ .value = .{ .type = Qualifier, .int = 1 } } } };
};
const TVec2i = extern struct {
    v: [2]c_int,
    pub const cpp_template = Template{ .name = "tpl::vec", .args = &.{ .{ .int = 2 }, .{ .type = c_int }, .{ .value = .{ .type = Qualifier, .int = 0 } } } };
};
const PairInt = extern struct {
    a: c_int,
    b: c_int,
    pub const cpp_template = Template{ .name = "Pair", .args = &.{.{ .type = c_int }} };
};
const FlagsT = extern struct {
    v: c_int,
    pub const cpp_template = Template{ .name = "Flags", .args = &.{ .{ .value = .{ .type = bool, .int = 1 } }, .{ .int = -1 } } };
};
const FlagsF = extern struct {
    v: c_int,
    pub const cpp_template = Template{ .name = "Flags", .args = &.{ .{ .value = .{ .type = bool, .int = 0 } }, .{ .int = 11 } } };
};
const ListVec3 = extern struct {
    n: c_int,
    alloc: extern struct { tag: c_int },
    pub const cpp_template = Template{
        .name = "tpl::List",
        .args = &.{ .{ .type = TVec3 }, .{ .template = .{ .name = "tpl::Alloc", .args = &.{.{ .type = TVec3 }} } } },
        .kind = .class,
    };
};
const BoxPtr = extern struct {
    val: *TVec3,
    pub const cpp_template = Template{ .name = "tpl::Box", .args = &.{.{ .type = *TVec3 }} };
};
const BoxChar = extern struct {
    val: u8,
    pub const cpp_template = Template{ .name = "tpl::Box", .args = &.{.{ .type = u8 }} };
};

const Plain = extern struct {
    n: c_int,
    pub const cpp_name = "ns::Plain";
};
const Poly = extern struct {
    _vptr: *const anyopaque,
    n: c_int,
    _tail: [4]u8,
    pub const cpp_name = "ns::Poly";
    pub const cpp_abi: ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
};
/// `struct Derived : virtual VBase`. A virtual base sits where the ABI puts
/// it, not where the declaration names it: both Itanium and MSVC place the
/// `VBase` subobject last, behind `Derived`'s own vtable pointer and members.
/// "test/fixture.cpp"'s `sizeof_derived` checks this at run time.
const Derived = extern struct {
    _vptr: *const anyopaque,
    b: c_int,
    _pad: [4]u8,
    _vbase_vptr: *const anyopaque,
    a: c_int,
    _tail: [4]u8,
    pub const cpp_name = "ns::Derived";
    pub const cpp_abi: ClassAbi = .managed_copy;
    pub const cpp_virtual_dtor = true;
    pub const cpp_virtual_bases = true;
};
const CellInt = extern struct {
    val: c_int,
    pub const cpp_template = Template{ .name = "tpl::Cell", .args = &.{.{ .type = c_int }} };
};

const Big = extern struct {
    a: c_int,
    b: c_int,
    c: c_int,
    d: c_int,
    e: c_int,
    pub const cpp_name = "ns::Big";
};
const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    pub const cpp_name = "ns::Color";
    pub const cpp_abi: ClassAbi = .trivial_copy;
};
const Rect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    pub const cpp_name = "ns::Rect";
    pub const cpp_abi: ClassAbi = .trivial_copy;
};
const Palette = extern struct {
    c: [2]Color,
    pub const cpp_name = "ns::Palette";
};
const Str = extern struct {
    buf: [24]u8,
    len: usize,
    pub const cpp_name = "ns::Str";
    pub const cpp_abi: ClassAbi = .managed_copy;
};
const Holder = extern struct {
    s: Str,
    pub const cpp_name = "ns::Holder";
    pub const cpp_abi: ClassAbi = .managed_copy;
};

const Case = struct { sig: Signature, itanium: []const u8, msvc: []const u8 };

const cases = [_]Case{
    .{ .sig = .{ .name = "add", .args = &.{ c_int, c_int }, .ret = c_int }, .itanium = "_Z3addii", .msvc = "?add@@YAHHH@Z" },
    .{ .sig = .{ .name = "nothing" }, .itanium = "_Z7nothingv", .msvc = "?nothing@@YAXXZ" },
    .{
        .sig = .{ .name = "mix", .args = &.{ u8, i8, uchar, c_short, c_ushort, c_uint, c_long, c_ulong, c_longlong, c_ulonglong }, .ret = c_uint },
        .itanium = "_Z3mixcahstjlmxy",
        .msvc = "?mix@@YAIDCEFGIJK_J_K@Z",
    },
    .{ .sig = .{ .name = "fp", .args = &.{ f32, f64 }, .ret = f64 }, .itanium = "_Z2fpfd", .msvc = "?fp@@YANMN@Z" },
    .{ .sig = .{ .name = "flip", .args = &.{bool}, .ret = bool }, .itanium = "_Z4flipb", .msvc = "?flip@@YA_N_N@Z" },
    .{ .sig = .{ .name = "strlen_", .args = &.{[*:0]const u8}, .ret = usize }, .itanium = "_Z7strlen_PKc", .msvc = "?strlen_@@YA_KPEBD@Z" },
    .{ .sig = .{ .name = "identity", .args = &.{?*anyopaque}, .ret = ?*anyopaque }, .itanium = "_Z8identityPv", .msvc = "?identity@@YAPEAXPEAX@Z" },
    .{ .sig = .{ .name = "first", .args = &.{ ?*c_int, ?*c_int }, .ret = ?*c_int }, .itanium = "_Z5firstPiS_", .msvc = "?first@@YAPEAHPEAH0@Z" },
    .{ .sig = .{ .name = "firstc", .args = &.{ ?*const c_int, ?*const c_int }, .ret = ?*const c_int }, .itanium = "_Z6firstcPKiS0_", .msvc = "?firstc@@YAPEBHPEBH0@Z" },
    .{ .sig = .{ .name = "wide", .args = &.{ wchar_t, char16_t, char32_t }, .ret = wchar_t }, .itanium = "_Z4widewDsDi", .msvc = "?wide@@YA_W_W_S_U@Z" },
    .{ .sig = .{ .name = "ns::add", .args = &.{ c_int, c_int }, .ret = c_int }, .itanium = "_ZN2ns3addEii", .msvc = "?add@ns@@YAHHH@Z" },
    .{ .sig = .{ .name = "ns::inner::sub", .args = &.{ c_longlong, c_longlong }, .ret = c_longlong }, .itanium = "_ZN2ns5inner3subExx", .msvc = "?sub@inner@ns@@YA_J_J0@Z" },
    .{ .sig = .{ .name = "ns::make_vec", .args = &.{ *Vec2, c_int, c_int }, .ret = *Vec2 }, .itanium = "_ZN2ns8make_vecEPNS_4Vec2Eii", .msvc = "?make_vec@ns@@YAPEAUVec2@1@PEAU21@HH@Z" },
    .{ .sig = .{ .name = "ns::vec_sum", .args = &.{*const Vec2}, .ret = c_int }, .itanium = "_ZN2ns7vec_sumEPKNS_4Vec2E", .msvc = "?vec_sum@ns@@YAHPEBUVec2@1@@Z" },
    .{ .sig = .{ .name = "ns::counter_new", .args = &.{ *Counter, c_int }, .ret = *Counter }, .itanium = "_ZN2ns11counter_newEPNS_7CounterEi", .msvc = "?counter_new@ns@@YAPEAUCounter@1@PEAU21@H@Z" },
    .{ .sig = .{ .name = "ns::Counter::get", .ret = c_int, .this = *const Counter }, .itanium = "_ZNK2ns7Counter3getEv", .msvc = "?get@Counter@ns@@QEBAHXZ" },
    .{ .sig = .{ .name = "ns::Counter::set", .args = &.{c_int}, .this = *Counter }, .itanium = "_ZN2ns7Counter3setEi", .msvc = "?set@Counter@ns@@QEAAXH@Z" },
    .{ .sig = .{ .name = "ns::Counter::addTo", .args = &.{*const Counter}, .ret = c_int, .this = *const Counter }, .itanium = "_ZNK2ns7Counter5addToEPKS0_", .msvc = "?addTo@Counter@ns@@QEBAHPEBU12@@Z" },
    .{ .sig = .{ .name = "ns::Counter::self", .ret = *Counter, .this = *Counter }, .itanium = "_ZN2ns7Counter4selfEv", .msvc = "?self@Counter@ns@@QEAAPEAU12@XZ" },
    // References.
    .{ .sig = .{ .name = "ref_inc", .args = &.{Ref(*c_int)}, .ret = Ref(*c_int) }, .itanium = "_Z7ref_incRi", .msvc = "?ref_inc@@YAAEAHAEAH@Z" },
    .{ .sig = .{ .name = "ref_sum", .args = &.{ Ref(*const c_int), Ref(*const c_int) }, .ret = c_int }, .itanium = "_Z7ref_sumRKiS0_", .msvc = "?ref_sum@@YAHAEBH0@Z" },
    .{ .sig = .{ .name = "take_rvalue", .args = &.{RRef(*c_int)}, .ret = c_int }, .itanium = "_Z11take_rvalueOi", .msvc = "?take_rvalue@@YAH$$QEAH@Z" },
    .{ .sig = .{ .name = "ns::vec_sum_ref", .args = &.{Ref(*const Vec2)}, .ret = c_int }, .itanium = "_ZN2ns11vec_sum_refERKNS_4Vec2E", .msvc = "?vec_sum_ref@ns@@YAHAEBUVec2@1@@Z" },
    .{ .sig = .{ .name = "ns::vec_scale", .args = &.{ Ref(*Vec2), c_int }, .ret = Ref(*Vec2) }, .itanium = "_ZN2ns9vec_scaleERNS_4Vec2Ei", .msvc = "?vec_scale@ns@@YAAEAUVec2@1@AEAU21@H@Z" },
    .{ .sig = .{ .name = "ns::vec_take", .args = &.{RRef(*Vec2)}, .ret = c_int }, .itanium = "_ZN2ns8vec_takeEONS_4Vec2E", .msvc = "?vec_take@ns@@YAH$$QEAUVec2@1@@Z" },
    .{ .sig = .{ .name = "ns::Counter::assign", .args = &.{Ref(*const Counter)}, .ret = c_int, .this = *Counter }, .itanium = "_ZN2ns7Counter6assignERKS0_", .msvc = "?assign@Counter@ns@@QEAAHAEBU12@@Z" },
    .{ .sig = .{ .name = "ns::ptr_ref", .args = &.{Ref(*const [*c]c_int)}, .ret = Ref(*const [*c]c_int) }, .itanium = "_ZN2ns7ptr_refERKPi", .msvc = "?ptr_ref@ns@@YAAEBQEAHAEBQEAH@Z" },
    .{ .sig = .{ .name = "ns::ptr_ptr", .args = &.{ *const [*c]c_int, *const [*c]const c_int }, .ret = c_int }, .itanium = "_ZN2ns7ptr_ptrEPKPiPKPKi", .msvc = "?ptr_ptr@ns@@YAHPEBQEAHPEBQEBH@Z" },
    // `T* const`: Itanium drops the top-level qualifier, MSVC spells it `Q`.
    .{ .sig = .{ .name = "ns::cptr_w", .args = &.{ConstPtr([*c]u8)}, .ret = c_int }, .itanium = "_ZN2ns6cptr_wEPc", .msvc = "?cptr_w@ns@@YAHQEAD@Z" },
    .{ .sig = .{ .name = "ns::cptr_r", .args = &.{ConstPtr([*c]const u8)}, .ret = c_int }, .itanium = "_ZN2ns6cptr_rEPKc", .msvc = "?cptr_r@ns@@YAHQEBD@Z" },
    // Only Itanium folds the two into one substitution; for MSVC they differ.
    .{ .sig = .{ .name = "ns::cptr_mix", .args = &.{ ConstPtr([*c]u8), [*c]u8 }, .ret = c_int }, .itanium = "_ZN2ns8cptr_mixEPcS0_", .msvc = "?cptr_mix@ns@@YAHQEADPEAD@Z" },
    .{ .sig = .{ .name = "ns::cptr_both", .args = &.{ ConstPtr([*c]const u8), ConstPtr([*c]const u8) }, .ret = c_int }, .itanium = "_ZN2ns9cptr_bothEPKcS1_", .msvc = "?cptr_both@ns@@YAHQEBD0@Z" },
    // MSVC returns a class from an instance method through a hidden pointer,
    // and from a static one in a register; Itanium uses a register for both.
    .{ .sig = .{ .name = "asVec", .this = *const Counter, .ret = Vec2 }, .itanium = "_ZNK2ns7Counter5asVecEv", .msvc = "?asVec@Counter@ns@@QEBA?AUVec2@2@XZ" },
    .{ .sig = .{ .name = "origin", .class = Counter, .ret = Vec2 }, .itanium = "_ZN2ns7Counter6originEv", .msvc = "?origin@Counter@ns@@SA?AUVec2@2@XZ" },
    // Operators. Itanium gives the unary and binary forms of one spelling
    // different codes; MSVC uses one code and tells them apart by arity.
    .{ .sig = .{ .name = ":+", .this = *const Ops, .args = &.{Ref(*const Ops)}, .ret = Ops }, .itanium = "_ZNK2ns3OpsplERKS0_", .msvc = "??HOps@ns@@QEBA?AU01@AEBU01@@Z" },
    .{ .sig = .{ .name = ":-", .this = *const Ops, .ret = Ops }, .itanium = "_ZNK2ns3OpsngEv", .msvc = "??GOps@ns@@QEBA?AU01@XZ" },
    .{ .sig = .{ .name = ":~", .this = *const Ops, .ret = Ops }, .itanium = "_ZNK2ns3OpscoEv", .msvc = "??SOps@ns@@QEBA?AU01@XZ" },
    .{ .sig = .{ .name = ":+=", .this = *Ops, .args = &.{Ref(*const Ops)}, .ret = Ref(*Ops) }, .itanium = "_ZN2ns3OpspLERKS0_", .msvc = "??YOps@ns@@QEAAAEAU01@AEBU01@@Z" },
    .{ .sig = .{ .name = ":==", .this = *const Ops, .args = &.{Ref(*const Ops)}, .ret = bool }, .itanium = "_ZNK2ns3OpseqERKS0_", .msvc = "??8Ops@ns@@QEBA_NAEBU01@@Z" },
    .{ .sig = .{ .name = ":[]", .this = *Ops, .args = &.{c_int}, .ret = Ref(*c_int) }, .itanium = "_ZN2ns3OpsixEi", .msvc = "??AOps@ns@@QEAAAEAHH@Z" },
    .{ .sig = .{ .name = ":()", .this = *const Ops, .args = &.{ c_int, c_int }, .ret = c_int }, .itanium = "_ZNK2ns3OpsclEii", .msvc = "??ROps@ns@@QEBAHHH@Z" },
    // Postfix `++` is the one that takes an unused int.
    .{ .sig = .{ .name = ":++", .this = *Ops, .args = &.{c_int}, .ret = Ops }, .itanium = "_ZN2ns3OpsppEi", .msvc = "??EOps@ns@@QEAA?AU01@H@Z" },
    // A conversion operator's target is its return type.
    .{ .sig = .{ .name = ":cast", .this = *const Ops, .ret = c_int }, .itanium = "_ZNK2ns3OpscviEv", .msvc = "??BOps@ns@@QEBAHXZ" },
    .{ .sig = .{ .name = ":delete", .class = Ops, .args = &.{*anyopaque} }, .itanium = "_ZN2ns3OpsdlEPv", .msvc = "??3Ops@ns@@SAXPEAX@Z" },
    // Free operators, `ns::` followed by `:*`. One parameter fewer decides arity.
    .{ .sig = .{ .name = "ns:::*", .args = &.{ Ref(*const Ops), c_int }, .ret = Ops }, .itanium = "_ZN2nsmlERKNS_3OpsEi", .msvc = "??Dns@@YA?AUOps@0@AEBU10@H@Z" },
    .{ .sig = .{ .name = "ns:::!", .args = &.{Ref(*const Ops)}, .ret = bool }, .itanium = "_ZN2nsntERKNS_3OpsE", .msvc = "??7ns@@YA_NAEBUOps@0@@Z" },
    // Function templates. Itanium spells the declared parameter (`RKT_`) and
    // adds the return type; MSVC spells the substituted one.
    .{ .sig = .{ .name = "ns::tpl_id", .template_args = &.{.{ .type = c_int }}, .args = &.{Ref(*const TParam(0))}, .ret = c_int }, .itanium = "_ZN2ns6tpl_idIiEEiRKT_", .msvc = "??$tpl_id@H@ns@@YAHAEBH@Z" },
    .{ .sig = .{ .name = "ns::tpl_id", .template_args = &.{.{ .type = Vec2 }}, .args = &.{Ref(*const TParam(0))}, .ret = c_int }, .itanium = "_ZN2ns6tpl_idINS_4Vec2EEEiRKT_", .msvc = "??$tpl_id@UVec2@ns@@@ns@@YAHAEBUVec2@0@@Z" },
    // T twice: Itanium back-references the second, MSVC repeats `H`.
    .{ .sig = .{ .name = "ns::tpl_echo", .template_args = &.{.{ .type = c_int }}, .args = &.{TParam(0)}, .ret = TParam(0) }, .itanium = "_ZN2ns8tpl_echoIiEET_S1_", .msvc = "??$tpl_echo@H@ns@@YAHH@Z" },
    .{ .sig = .{ .name = "take", .this = *const Tpl, .template_args = &.{.{ .type = c_int }}, .args = &.{Ref(*const TParam(0))}, .ret = c_int }, .itanium = "_ZNK2ns3Tpl4takeIiEEiRKT_", .msvc = "??$take@H@Tpl@ns@@QEBAHAEBH@Z" },
    .{ .sig = .{ .name = "make", .class = Tpl, .template_args = &.{.{ .type = c_int }}, .args = &.{Ref(*const TParam(0))}, .ret = c_int }, .itanium = "_ZN2ns3Tpl4makeIiEEiRKT_", .msvc = "??$make@H@Tpl@ns@@SAHAEBH@Z" },
    .{ .sig = .{ .name = "get", .ret = c_int, .this = *const Counter }, .itanium = "_ZNK2ns7Counter3getEv", .msvc = "?get@Counter@ns@@QEBAHXZ" },
    // Class-template specializations.
    .{ .sig = .{ .name = "pair_sum", .args = &.{Ref(*const PairInt)}, .ret = c_int }, .itanium = "_Z8pair_sumRK4PairIiE", .msvc = "?pair_sum@@YAHAEBU?$Pair@H@@@Z" },
    .{ .sig = .{ .name = "flags", .args = &.{ *FlagsT, *FlagsF }, .ret = c_int }, .itanium = "_Z5flagsP5FlagsILb1ELin1EEPS_ILb0ELi11EE", .msvc = "?flags@@YAHPEAU?$Flags@$00$0?0@@PEAU?$Flags@$0A@$0L@@@@Z" },
    .{ .sig = .{ .name = "tpl::sum3", .args = &.{ Ref(*const TVec3), Ref(*const TVec3) }, .ret = f32 }, .itanium = "_ZN3tpl4sum3ERKNS_3vecILi3EfLNS_9qualifierE1EEES4_", .msvc = "?sum3@tpl@@YAMAEBU?$vec@$02M$00@1@0@Z" },
    .{ .sig = .{ .name = "tpl::dims", .args = &.{ *TVec3, *TVec2i }, .ret = c_int }, .itanium = "_ZN3tpl4dimsEPNS_3vecILi3EfLNS_9qualifierE1EEEPNS0_ILi2EiLS1_0EEE", .msvc = "?dims@tpl@@YAHPEAU?$vec@$02M$00@1@PEAU?$vec@$01H$0A@@1@@Z" },
    .{ .sig = .{ .name = "tpl::list_count", .args = &.{Ref(*const ListVec3)}, .ret = c_int }, .itanium = "_ZN3tpl10list_countERKNS_4ListINS_3vecILi3EfLNS_9qualifierE1EEENS_5AllocIS3_EEEE", .msvc = "?list_count@tpl@@YAHAEBV?$List@U?$vec@$02M$00@tpl@@U?$Alloc@U?$vec@$02M$00@tpl@@@2@@1@@Z" },
    .{ .sig = .{ .name = "len", .ret = c_int, .this = *const TVec3 }, .itanium = "_ZNK3tpl3vecILi3EfLNS_9qualifierE1EE3lenEv", .msvc = "?len@?$vec@$02M$00@tpl@@QEBAHXZ" },
    .{ .sig = .{ .name = "first", .ret = f32, .this = *const TVec3 }, .itanium = "_ZNK3tpl3vecILi3EfLNS_9qualifierE1EE5firstEv", .msvc = "?first@?$vec@$02M$00@tpl@@QEBAMXZ" },
    .{ .sig = .{ .name = "fill", .args = &.{f32}, .this = *TVec3 }, .itanium = "_ZN3tpl3vecILi3EfLNS_9qualifierE1EE4fillEf", .msvc = "?fill@?$vec@$02M$00@tpl@@QEAAXM@Z" },
    .{ .sig = .{ .name = "dim", .ret = c_int, .class = TVec3 }, .itanium = "_ZN3tpl3vecILi3EfLNS_9qualifierE1EE3dimEv", .msvc = "?dim@?$vec@$02M$00@tpl@@SAHXZ" },
    .{ .sig = .{ .name = "len", .ret = c_int, .this = *const TVec2i }, .itanium = "_ZNK3tpl3vecILi2EiLNS_9qualifierE0EE3lenEv", .msvc = "?len@?$vec@$01H$0A@@tpl@@QEBAHXZ" },
    .{ .sig = .{ .name = "count", .ret = c_int, .this = *const ListVec3 }, .itanium = "_ZNK3tpl4ListINS_3vecILi3EfLNS_9qualifierE1EEENS_5AllocIS3_EEE5countEv", .msvc = "?count@?$List@U?$vec@$02M$00@tpl@@U?$Alloc@U?$vec@$02M$00@tpl@@@2@@tpl@@QEBAHXZ" },
    .{ .sig = .{ .name = "get", .ret = *TVec3, .this = *const BoxPtr }, .itanium = "_ZNK3tpl3BoxIPNS_3vecILi3EfLNS_9qualifierE1EEEE3getEv", .msvc = "?get@?$Box@PEAU?$vec@$02M$00@tpl@@@tpl@@QEBAPEAU?$vec@$02M$00@2@XZ" },
    .{ .sig = .{ .name = "get", .ret = u8, .this = *const BoxChar }, .itanium = "_ZNK3tpl3BoxIcE3getEv", .msvc = "?get@?$Box@D@tpl@@QEBADXZ" },
    .{ .sig = .{ .name = "*", .args = &.{c_int}, .this = *Plain }, .itanium = "_ZN2ns5PlainC2Ei", .msvc = "??0Plain@ns@@QEAA@H@Z" },
    .{ .sig = .{ .name = "ns::Plain::*", .args = &.{c_int}, .this = *Plain }, .itanium = "_ZN2ns5PlainC2Ei", .msvc = "??0Plain@ns@@QEAA@H@Z" },
    .{ .sig = .{ .name = "~", .this = *Plain }, .itanium = "_ZN2ns5PlainD2Ev", .msvc = "??1Plain@ns@@QEAA@XZ" },
    .{ .sig = .{ .name = "*", .this = *Poly }, .itanium = "_ZN2ns4PolyC2Ev", .msvc = "??0Poly@ns@@QEAA@XZ" },
    .{ .sig = .{ .name = "~", .this = *Poly }, .itanium = "_ZN2ns4PolyD2Ev", .msvc = "??1Poly@ns@@UEAA@XZ" },
    .{ .sig = .{ .name = "f", .ret = c_int, .this = *Poly, .virtual = true }, .itanium = "_ZN2ns4Poly1fEv", .msvc = "?f@Poly@ns@@UEAAHXZ" },
    .{ .sig = .{ .name = "*", .args = &.{c_int}, .this = *Derived }, .itanium = "_ZN2ns7DerivedC1Ei", .msvc = "??0Derived@ns@@QEAA@H@Z" },
    .{ .sig = .{ .name = "~", .this = *Derived }, .itanium = "_ZN2ns7DerivedD1Ev", .msvc = "??_DDerived@ns@@QEAAXXZ" },
    .{ .sig = .{ .name = "*", .args = &.{c_int}, .this = *CellInt }, .itanium = "_ZN3tpl4CellIiEC2Ei", .msvc = "??0?$Cell@H@tpl@@QEAA@H@Z" },
    .{ .sig = .{ .name = "~", .this = *CellInt }, .itanium = "_ZN3tpl4CellIiED2Ev", .msvc = "??1?$Cell@H@tpl@@QEAA@XZ" },
    // Classes by value.
    .{ .sig = .{ .name = "ns::vec_make", .args = &.{ c_int, c_int }, .ret = Vec2 }, .itanium = "_ZN2ns8vec_makeEii", .msvc = "?vec_make@ns@@YA?AUVec2@1@HH@Z" },
    .{ .sig = .{ .name = "ns::vec_dot", .args = &.{ Vec2, Vec2 }, .ret = c_int }, .itanium = "_ZN2ns7vec_dotENS_4Vec2ES0_", .msvc = "?vec_dot@ns@@YAHUVec2@1@0@Z" },
    .{ .sig = .{ .name = "ns::big_make", .args = &.{c_int}, .ret = Big }, .itanium = "_ZN2ns8big_makeEi", .msvc = "?big_make@ns@@YA?AUBig@1@H@Z" },
    .{ .sig = .{ .name = "ns::color_make", .args = &.{ c_int, c_int, c_int, c_int }, .ret = Color }, .itanium = "_ZN2ns10color_makeEiiii", .msvc = "?color_make@ns@@YA?AUColor@1@HHHH@Z" },
    .{ .sig = .{ .name = "ns::color_sum", .args = &.{Color}, .ret = c_int }, .itanium = "_ZN2ns9color_sumENS_5ColorE", .msvc = "?color_sum@ns@@YAHUColor@1@@Z" },
    .{ .sig = .{ .name = "at", .args = &.{c_int}, .ret = Color, .this = *const Palette }, .itanium = "_ZNK2ns7Palette2atEi", .msvc = "?at@Palette@ns@@QEBA?AUColor@2@H@Z" },
    .{ .sig = .{ .name = "mix", .args = &.{ Color, Color }, .ret = c_int, .this = *const Palette }, .itanium = "_ZNK2ns7Palette3mixENS_5ColorES1_", .msvc = "?mix@Palette@ns@@QEBAHUColor@2@0@Z" },
    .{ .sig = .{ .name = "ns::str_make", .args = &.{[*:0]const u8}, .ret = Str }, .itanium = "_ZN2ns8str_makeEPKc", .msvc = "?str_make@ns@@YA?AUStr@1@PEBD@Z" },
    .{ .sig = .{ .name = "ns::str_len", .args = &.{Str}, .ret = usize }, .itanium = "_ZN2ns7str_lenENS_3StrE", .msvc = "?str_len@ns@@YA_KUStr@1@@Z" },
    .{ .sig = .{ .name = "get", .ret = Str, .this = *const Holder }, .itanium = "_ZNK2ns6Holder3getEv", .msvc = "?get@Holder@ns@@QEBA?AUStr@2@XZ" },
    .{ .sig = .{ .name = "take", .args = &.{Str}, .ret = usize, .this = *Holder }, .itanium = "_ZN2ns6Holder4takeENS_3StrE", .msvc = "?take@Holder@ns@@QEAA_KUStr@2@@Z" },
};

test "itanium mangling matches clang" {
    inline for (cases) |c| {
        try std.testing.expectEqualStrings(c.itanium, comptime mangledName(.itanium, c.sig));
    }
}

test "msvc mangling matches clang" {
    inline for (cases) |c| {
        try std.testing.expectEqualStrings(c.msvc, comptime mangledName(.msvc, c.sig));
    }
}

test "named type without cpp_name uses its Zig name; kinds" {
    const Foo = opaque {};
    const E = enum(c_int) { a, _ };
    const K = opaque {
        pub const cpp_name = "K";
        pub const cpp_kind: Kind = .class;
    };
    try std.testing.expectEqualStrings("_Z1fP3FooPK1EP1K", comptime mangledName(.itanium, .{ .name = "f", .args = &.{ *Foo, *const E, *K } }));
    try std.testing.expectEqualStrings("?f@@YAXPEAUFoo@@PEBW4E@@PEAVK@@@Z", comptime mangledName(.msvc, .{ .name = "f", .args = &.{ *Foo, *const E, *K } }));
}

test "msvc back-reference tables cap at ten entries" {
    const S = opaque {};
    const P = *S;
    const args = [_]type{ P, P, P, P, P, P, P, P, P, P, P, P };
    try std.testing.expectEqualStrings("?f@@YAXPEAUS@@00000000000@Z", comptime mangledName(.msvc, .{ .name = "f", .args = &args }));
}

test "free functions" {
    const add = bindFn(&.{ c_int, c_int }, c_int, "add");
    try std.testing.expectEqual(5, add(2, 3));

    const nothing = bindFn(&.{}, void, "nothing");
    nothing();

    const mix = bindFn(&.{ u8, i8, uchar, c_short, c_ushort, c_uint, c_long, c_ulong, c_longlong, c_ulonglong }, c_uint, "mix");
    try std.testing.expectEqual(55, mix(1, 2, @fromBackingInt(@intCast(3)), 4, 5, 6, 7, 8, 9, 10));

    const fp = bindFn(&.{ f32, f64 }, f64, "fp");
    try std.testing.expectEqual(3.5, fp(1.5, 2.0));

    const flip = bindFn(&.{bool}, bool, "flip");
    try std.testing.expect(flip(false));

    const strlen_ = bindFn(&.{[*:0]const u8}, usize, "strlen_");
    try std.testing.expectEqual(5, strlen_("hello"));

    const identity = bindFn(&.{?*anyopaque}, ?*anyopaque, "identity");
    var x: u8 = 0;
    try std.testing.expectEqual(@as(?*anyopaque, &x), identity(&x));

    const first = bindFn(&.{ ?*c_int, ?*c_int }, ?*c_int, "first");
    var a: c_int = 1;
    try std.testing.expectEqual(@as(?*c_int, &a), first(null, &a));

    const wide = bindFn(&.{ wchar_t, char16_t, char32_t }, wchar_t, "wide");
    try std.testing.expectEqual(@as(wchar_t, @fromBackingInt(@intCast(6))), wide(@fromBackingInt(@intCast(1)), @fromBackingInt(@intCast(2)), @fromBackingInt(@intCast(3))));
}

test "namespaced functions" {
    const add = bindFn(&.{ c_int, c_int }, c_int, "ns::add");
    try std.testing.expectEqual(23, add(2, 3));

    const sub = bindFn(&.{ c_longlong, c_longlong }, c_longlong, "ns::inner::sub");
    try std.testing.expectEqual(-1, sub(2, 3));

    const make_vec = bindFn(&.{ *Vec2, c_int, c_int }, *Vec2, "ns::make_vec");
    const vec_sum = bindFn(&.{*const Vec2}, c_int, "ns::vec_sum");
    var v: Vec2 = undefined;
    try std.testing.expectEqual(&v, make_vec(&v, 4, 5));
    try std.testing.expectEqual(9, vec_sum(&v));
}

test "member functions" {
    const counter_new = bindFn(&.{ *Counter, c_int }, *Counter, "ns::counter_new");
    const get = bindMethod(*const Counter, &.{}, c_int, "ns::Counter::get");
    const set = bindMethod(*Counter, &.{c_int}, void, "ns::Counter::set");
    const addTo = bindMethod(*const Counter, &.{*const Counter}, c_int, "ns::Counter::addTo");
    const self = bindMethod(*Counter, &.{}, *Counter, "ns::Counter::self");

    var a: Counter = undefined;
    var b: Counter = undefined;
    _ = counter_new(&a, 10);
    _ = counter_new(&b, 32);
    try std.testing.expectEqual(10, get(&a));
    set(&a, 11);
    try std.testing.expectEqual(11, a.n);
    try std.testing.expectEqual(43, addTo(&a, &b));
    try std.testing.expectEqual(&b, self(&b));
}

test "reference parameters and returns" {
    const ref_inc = bindFn(&.{Ref(*c_int)}, Ref(*c_int), "ref_inc");
    var x: c_int = 41;
    try std.testing.expectEqual(&x, ref_inc(&x));
    try std.testing.expectEqual(42, x);

    const ref_sum = bindFn(&.{ Ref(*const c_int), Ref(*const c_int) }, c_int, "ref_sum");
    const two: c_int = 2;
    try std.testing.expectEqual(44, ref_sum(&x, &two));

    const take_rvalue = bindFn(&.{RRef(*c_int)}, c_int, "take_rvalue");
    try std.testing.expectEqual(84, take_rvalue(&x));

    const vec_sum_ref = bindFn(&.{Ref(*const Vec2)}, c_int, "ns::vec_sum_ref");
    const vec_scale = bindFn(&.{ Ref(*Vec2), c_int }, Ref(*Vec2), "ns::vec_scale");
    const vec_take = bindFn(&.{RRef(*Vec2)}, c_int, "ns::vec_take");
    var v = Vec2{ .x = 3, .y = 4 };
    try std.testing.expectEqual(7, vec_sum_ref(&v));
    try std.testing.expectEqual(&v, vec_scale(&v, 10));
    try std.testing.expectEqual(Vec2{ .x = 30, .y = 40 }, v);
    try std.testing.expectEqual(-10, vec_take(&v));

    const assign = bindMethod(*Counter, &.{Ref(*const Counter)}, c_int, "ns::Counter::assign");
    var a = Counter{ .n = 0 };
    const b = Counter{ .n = 9 };
    try std.testing.expectEqual(9, assign(&a, &b));
    try std.testing.expectEqual(9, a.n);

    const ptr_ref = bindFn(&.{Ref(*const [*c]c_int)}, Ref(*const [*c]c_int), "ns::ptr_ref");
    const p: [*c]c_int = &x;
    try std.testing.expectEqual(&p, ptr_ref(&p));

    const cptr_w = bindFn(&.{ConstPtr([*c]u8)}, c_int, "ns::cptr_w");
    const cptr_both = bindFn(&.{ ConstPtr([*c]const u8), ConstPtr([*c]const u8) }, c_int, "ns::cptr_both");
    var ch: u8 = 7;
    try std.testing.expectEqual(7, cptr_w(&ch));
    try std.testing.expectEqual(14, cptr_both(&ch, &ch));

    const ptr_ptr = bindFn(&.{ *const [*c]c_int, *const [*c]const c_int }, c_int, "ns::ptr_ptr");
    const cp: [*c]const c_int = &two;
    try std.testing.expectEqual(44, ptr_ptr(&p, &cp));
}

test "class-template specializations" {
    const pair_sum = bindFn(&.{Ref(*const PairInt)}, c_int, "pair_sum");
    try std.testing.expectEqual(3, pair_sum(&.{ .a = 1, .b = 2 }));

    const flags = bindFn(&.{ *FlagsT, *FlagsF }, c_int, "flags");
    var ft = FlagsT{ .v = 100 };
    var ff = FlagsF{ .v = 11 };
    try std.testing.expectEqual(111, flags(&ft, &ff));

    const fill = bindMethod(*TVec3, &.{f32}, void, "fill");
    const first = bindMethod(*const TVec3, &.{}, f32, "first");
    const len = bindMethod(*const TVec3, &.{}, c_int, "len");
    const dim = bindStatic(TVec3, &.{}, c_int, "dim");
    var v: TVec3 = undefined;
    fill(&v, 2.5);
    try std.testing.expectEqual(2.5, first(&v));
    try std.testing.expectEqual(3, len(&v));
    try std.testing.expectEqual(31, dim());

    const dim2 = bindStatic(TVec2i, &.{}, c_int, "dim");
    try std.testing.expectEqual(20, dim2());

    const sum3 = bindFn(&.{ Ref(*const TVec3), Ref(*const TVec3) }, f32, "tpl::sum3");
    try std.testing.expectEqual(5.0, sum3(&v, &v));

    const dims = bindFn(&.{ *TVec3, *TVec2i }, c_int, "tpl::dims");
    var v2: TVec2i = undefined;
    try std.testing.expectEqual(302, dims(&v, &v2));

    const list_count = bindFn(&.{Ref(*const ListVec3)}, c_int, "tpl::list_count");
    const count = bindMethod(*const ListVec3, &.{}, c_int, "count");
    const l = ListVec3{ .n = 5, .alloc = .{ .tag = 7 } };
    try std.testing.expectEqual(12, list_count(&l));
    try std.testing.expectEqual(12, count(&l));

    const get_ptr = bindMethod(*const BoxPtr, &.{}, *TVec3, "get");
    const get_char = bindMethod(*const BoxChar, &.{}, u8, "get");
    try std.testing.expectEqual(&v, get_ptr(&.{ .val = &v }));
    try std.testing.expectEqual('z', get_char(&.{ .val = 'z' }));
}

test "constructors and destructors" {
    const dtor_calls = bindFn(&.{}, c_int, "ns::dtor_calls");
    const before = dtor_calls();

    const plain_ctor = bindMethod(*Plain, &.{c_int}, void, "*");
    const plain_dtor = bindMethod(*Plain, &.{}, void, "~");
    var p: Plain = undefined;
    plain_ctor(&p, 42);
    try std.testing.expectEqual(42, p.n);
    plain_dtor(&p);
    try std.testing.expectEqual(-1, p.n);

    const poly_ctor = bindMethod(*Poly, &.{}, void, "*");
    const poly_dtor = bindMethod(*Poly, &.{}, void, "~");
    const poly_f = cpp.bind(.{ .name = "f", .ret = c_int, .this = *Poly, .virtual = true });
    var q: Poly = undefined;
    poly_ctor(&q);
    try std.testing.expectEqual(1, q.n);
    try std.testing.expectEqual(10, poly_f(&q));
    poly_dtor(&q);
    try std.testing.expectEqual(-2, q.n);

    const sizeof_derived = bindFn(&.{}, usize, "ns::sizeof_derived");
    const derived_sum = bindFn(&.{Ref(*const Derived)}, c_int, "ns::derived_sum");
    const derived_ctor = bindMethod(*Derived, &.{c_int}, void, "*");
    const derived_dtor = bindMethod(*Derived, &.{}, void, "~");
    try std.testing.expectEqual(@sizeOf(Derived), sizeof_derived());
    var d: Derived = undefined;
    derived_ctor(&d, 7);
    try std.testing.expectEqual(207, derived_sum(&d));
    // The members the Zig layout claims, read where it claims they are.
    try std.testing.expectEqual(2, d.a);
    try std.testing.expectEqual(7, d.b);
    derived_dtor(&d);

    const cell_ctor = bindMethod(*CellInt, &.{c_int}, void, "*");
    const cell_dtor = bindMethod(*CellInt, &.{}, void, "~");
    const cell_get = bindMethod(*const CellInt, &.{}, c_int, "get");
    var c: CellInt = undefined;
    cell_ctor(&c, 99);
    try std.testing.expectEqual(99, cell_get(&c));
    cell_dtor(&c);
    try std.testing.expectEqual(0, c.val);

    try std.testing.expectEqual(before + 4, dtor_calls());
}

test "visible signatures of by-value classes" {
    try std.testing.expectEqual(*const fn (c_int, c_int) callconv(.c) Color, *const cpp.FnType(.{ .name = "ns::color_make", .args = &.{ c_int, c_int }, .ret = Color }));
    try std.testing.expectEqual(*const fn (*Str, *const Holder) callconv(.c) void, *const cpp.FnType(.{ .name = "get", .ret = Str, .this = *const Holder }));
    try std.testing.expectEqual(*const fn (*Holder, *Str) callconv(.c) usize, *const cpp.FnType(.{ .name = "take", .args = &.{Str}, .ret = usize, .this = *Holder }));
}

test "c_struct by value" {
    const vec_make = bindFn(&.{ c_int, c_int }, Vec2, "ns::vec_make");
    const vec_dot = bindFn(&.{ Vec2, Vec2 }, c_int, "ns::vec_dot");
    const v = vec_make(3, 4);
    try std.testing.expectEqual(Vec2{ .x = 3, .y = 4 }, v);
    try std.testing.expectEqual(25, vec_dot(v, v));

    const big_make = bindFn(&.{c_int}, Big, "ns::big_make");
    const big_sum = bindFn(&.{Big}, c_int, "ns::big_sum");
    const b = big_make(1);
    try std.testing.expectEqual(5, b.e);
    try std.testing.expectEqual(15, big_sum(b));
}

test "trivial_copy by value" {
    const color_make = bindFn(&.{ c_int, c_int, c_int, c_int }, Color, "ns::color_make");
    const color_sum = bindFn(&.{Color}, c_int, "ns::color_sum");
    const c = color_make(1, 2, 3, 4);
    try std.testing.expectEqual(Color{ .r = 1, .g = 2, .b = 3, .a = 4 }, c);
    try std.testing.expectEqual(10, color_sum(c));

    const rect_make = bindFn(&.{ f32, f32, f32, f32 }, Rect, "ns::rect_make");
    const rect_area = bindFn(&.{Rect}, f32, "ns::rect_area");
    const r = rect_make(1, 2, 3, 4);
    try std.testing.expectEqual(Rect{ .x = 1, .y = 2, .w = 3, .h = 4 }, r);
    try std.testing.expectEqual(12, rect_area(r));

    const at = bindMethod(*const Palette, &.{c_int}, Color, "at");
    const bounds = bindMethod(*const Palette, &.{}, Rect, "bounds");
    const mix = bindMethod(*const Palette, &.{ Color, Color }, c_int, "mix");
    const p = Palette{ .c = .{ .{ .r = 10, .g = 0, .b = 0, .a = 0 }, .{ .r = 20, .g = 1, .b = 1, .a = 1 } } };
    try std.testing.expectEqual(p.c[1], at(&p, 1));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 10, .h = 20 }, bounds(&p));
    try std.testing.expectEqual(10 * 1000 + 23 + 10, mix(&p, p.c[0], p.c[1]));
}

test "managed_copy by value" {
    const live = bindFn(&.{}, c_int, "ns::live_strs");
    const base = live();

    const str_make = bindFn(&.{[*:0]const u8}, Str, "ns::str_make");
    var s: Str = undefined;
    str_make(&s, "hello");
    try std.testing.expectEqual(5, s.len);
    try std.testing.expectEqual(base + 1, live());

    const str_len = bindFn(&.{Str}, usize, "ns::str_len");
    try std.testing.expectEqual(5, str_len(&s));
    try std.testing.expectEqual(base, live());

    const str_len2 = bindFn(&.{ Str, Str }, usize, "ns::str_len2");
    var a: Str = undefined;
    var b: Str = undefined;
    str_make(&a, "ab");
    str_make(&b, "xyz");
    try std.testing.expectEqual(203, str_len2(&a, &b));
    try std.testing.expectEqual(base, live());

    const holder_ctor = bindMethod(*Holder, &.{[*:0]const u8}, void, "*");
    const holder_dtor = bindMethod(*Holder, &.{}, void, "~");
    const get = bindMethod(*const Holder, &.{}, Str, "get");
    const take = bindMethod(*Holder, &.{Str}, usize, "take");
    var h: Holder = undefined;
    holder_ctor(&h, "four");
    var got: Str = undefined;
    get(&got, &h);
    try std.testing.expectEqual(4, got.len);
    try std.testing.expectEqual(base + 2, live());
    try std.testing.expectEqual(404, take(&h, &got));
    try std.testing.expectEqual(base + 1, live());
    holder_dtor(&h);
    try std.testing.expectEqual(base, live());
}

test "function template specializations" {
    const int_arg: []const cpp.TemplateArg = &.{.{ .type = c_int }};

    const id_int = cpp.bind(.{ .name = "ns::tpl_id", .template_args = int_arg, .args = &.{Ref(*const TParam(0))}, .ret = c_int });
    var n: c_int = 41;
    try std.testing.expectEqual(42, id_int(&n));

    const id_vec = cpp.bind(.{ .name = "ns::tpl_id", .template_args = &.{.{ .type = Vec2 }}, .args = &.{Ref(*const TParam(0))}, .ret = c_int });
    const v = Vec2{ .x = 3, .y = 4 };
    try std.testing.expectEqual(34, id_vec(&v));

    const echo = cpp.bind(.{ .name = "ns::tpl_echo", .template_args = int_arg, .args = &.{TParam(0)}, .ret = TParam(0) });
    try std.testing.expectEqual(7, echo(7));

    const take = cpp.bind(.{ .name = "take", .this = *const Tpl, .template_args = int_arg, .args = &.{Ref(*const TParam(0))}, .ret = c_int });
    const t = Tpl{ .n = 5 };
    var one: c_int = 1;
    try std.testing.expectEqual(501, take(&t, &one));

    const make = cpp.bind(.{ .name = "make", .class = Tpl, .template_args = int_arg, .args = &.{Ref(*const TParam(0))}, .ret = c_int });
    var three: c_int = 3;
    try std.testing.expectEqual(9, make(&three));
}

test "a class returned from a method" {
    const as_vec = cpp.bind(.{ .name = "asVec", .this = *const Counter, .ret = Vec2 });
    const origin = cpp.bind(.{ .name = "origin", .class = Counter, .ret = Vec2 });
    const c = Counter{ .n = 6 };
    try std.testing.expectEqual(Vec2{ .x = 6, .y = 12 }, as_vec(&c));
    try std.testing.expectEqual(Vec2{ .x = 0, .y = 0 }, origin());
}

test "operator overloads" {
    const add = cpp.bind(.{ .name = ":+", .this = *const Ops, .args = &.{Ref(*const Ops)}, .ret = Ops });
    const neg = cpp.bind(.{ .name = ":-", .this = *const Ops, .ret = Ops });
    const not = cpp.bind(.{ .name = ":~", .this = *const Ops, .ret = Ops });
    const add_assign = cpp.bind(.{ .name = ":+=", .this = *Ops, .args = &.{Ref(*const Ops)}, .ret = Ref(*Ops) });
    const eq = cpp.bind(.{ .name = ":==", .this = *const Ops, .args = &.{Ref(*const Ops)}, .ret = bool });
    const index = cpp.bind(.{ .name = ":[]", .this = *Ops, .args = &.{c_int}, .ret = Ref(*c_int) });
    const call = cpp.bind(.{ .name = ":()", .this = *const Ops, .args = &.{ c_int, c_int }, .ret = c_int });
    const post_inc = cpp.bind(.{ .name = ":++", .this = *Ops, .args = &.{c_int}, .ret = Ops });
    const to_int = cpp.bind(.{ .name = ":cast", .this = *const Ops, .ret = c_int });
    const scale = cpp.bind(.{ .name = "ns:::*", .args = &.{ Ref(*const Ops), c_int }, .ret = Ops });
    const is_zero = cpp.bind(.{ .name = "ns:::!", .args = &.{Ref(*const Ops)}, .ret = bool });

    var a: Ops = .{ .x = 3 };
    const b: Ops = .{ .x = 4 };
    try std.testing.expectEqual(Ops{ .x = 7 }, add(&a, &b));
    try std.testing.expectEqual(Ops{ .x = -3 }, neg(&a));
    try std.testing.expectEqual(Ops{ .x = ~@as(c_int, 3) }, not(&a));
    try std.testing.expectEqual(true, eq(&a, &Ops{ .x = 3 }));
    try std.testing.expectEqual(323, call(&a, 3, 2));
    try std.testing.expectEqual(3, to_int(&a));
    try std.testing.expectEqual(Ops{ .x = 15 }, scale(&a, 5));
    try std.testing.expectEqual(false, is_zero(&a));
    try std.testing.expectEqual(true, is_zero(&Ops{ .x = 0 }));

    try std.testing.expectEqual(Ops{ .x = 3 }, post_inc(&a, 0));
    try std.testing.expectEqual(4, a.x);
    index(&a, 0).* = 9;
    try std.testing.expectEqual(9, a.x);
    try std.testing.expectEqual(&a, add_assign(&a, &b));
    try std.testing.expectEqual(13, a.x);
}
