// koka/truetype/registry.kk — process-lifetime font registry.
//
// The bridge calls `register(name, bytes)` once per bundled font at
// app launch; the page composer calls `lookup(name)` when it needs
// to lay out a string in that face. One slot per name; re-register
// replaces.
//
// `font-info` is the parsed handle from `truetype/font.kk` (offsets
// into the byte buffer, no glyph cache yet). The registry holds the
// bytes alongside it because every glyph extraction reads from
// those bytes — the registry must keep them alive for the process
// lifetime.

module truetype/registry

import truetype/be_bytes
import truetype/font

pub struct registered-font
  name : string
  info : font-info

pub alias font-registry = ref<global, list<registered-font>>

pub fun new-font-registry() : alloc<global> font-registry
  ref([])

// Parse the bytes via init-font; on success, drop any prior entry
// with the same name and prepend the new one. Errors during parse
// become a no-op so the bridge never has to propagate Koka exns
// across the FFI.
pub fun register(r : font-registry, name : string, bytes : bytes)
        : <pure, read<global>, write<global>> ()
  match try-parse(bytes)
    Nothing -> ()
    Just(info) ->
      val updated = Cons(Registered-font(name, info), drop-by-name(!r, name))
      r := updated

fun try-parse(bytes : bytes) : div maybe<font-info>
  error/try({
    val offset = get-font-offset-for-index(bytes, 0)
    if offset < 0 then throw("not a font")
    else init-font(bytes, offset)
  }).maybe

fun drop-by-name(rs : list<registered-font>, target : string) : list<registered-font>
  rs.filter(fn(f) f.name != target)

pub fun lookup(r : font-registry, target : string)
        : <div, read<global>> maybe<font-info>
  lookup-loop(!r, target)

fun lookup-loop(rs : list<registered-font>, target : string) : div maybe<font-info>
  match rs
    Nil -> Nothing
    Cons(f, rest) -> if f.name == target then Just(f.info)
                     else lookup-loop(rest, target)

pub fun registry-names(r : font-registry) : <read<global>> list<string>
  (!r).map(fn(f) f.name)
