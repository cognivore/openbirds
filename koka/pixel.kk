// koka/pixel.kk — tightly-typed primitives for the pixel framebuffer.
//
// Every dimension and colour component is its own type. The compiler
// will refuse code that swaps `width` and `height`, multiplies an
// X coordinate by a Y coordinate by accident, or stores a green
// channel where a blue channel was expected. Smart constructors
// validate ranges at the perimeter; once a value is in scope, its
// invariants hold.
//
// Sizes are clamped to 16384 (matches Metal's max texture dimension
// on Apple Silicon) so we can't accidentally allocate the universe.

module pixel

// --- dimensions --------------------------------------------------------------

pub value struct width
  pixels : int

pub value struct height
  pixels : int

// Smart constructors. Range-check at the perimeter; everything inside
// the module trusts the invariant.
pub fun mk-width(n : int) : exn width
  if n <= 0 || n > 16384 then
    throw("invalid width: " ++ n.show)
  else
    Width(n)

pub fun mk-height(n : int) : exn height
  if n <= 0 || n > 16384 then
    throw("invalid height: " ++ n.show)
  else
    Height(n)

// --- coordinates -------------------------------------------------------------

pub value struct pixel-x
  col : int

pub value struct pixel-y
  row : int

pub fun mk-pixel-x(n : int, w : width) : exn pixel-x
  if n < 0 || n >= w.pixels then
    throw("pixel-x " ++ n.show ++ " out of [0, " ++ w.pixels.show ++ ")")
  else
    Pixel-x(n)

pub fun mk-pixel-y(n : int, h : height) : exn pixel-y
  if n < 0 || n >= h.pixels then
    throw("pixel-y " ++ n.show ++ " out of [0, " ++ h.pixels.show ++ ")")
  else
    Pixel-y(n)

// --- colour ------------------------------------------------------------------
//
// Four named newtypes so an `rgba` constructor cannot be invoked with
// components in the wrong order. Each component is 0..255; smart
// constructors enforce.

pub value struct red
  byte : int

pub value struct green
  byte : int

pub value struct blue
  byte : int

pub value struct alpha
  byte : int

pub fun mk-red(n : int) : exn red
  if n < 0 || n > 255 then throw("red byte out of range: " ++ n.show)
  else Red(n)

pub fun mk-green(n : int) : exn green
  if n < 0 || n > 255 then throw("green byte out of range: " ++ n.show)
  else Green(n)

pub fun mk-blue(n : int) : exn blue
  if n < 0 || n > 255 then throw("blue byte out of range: " ++ n.show)
  else Blue(n)

pub fun mk-alpha(n : int) : exn alpha
  if n < 0 || n > 255 then throw("alpha byte out of range: " ++ n.show)
  else Alpha(n)

pub value struct rgba
  r : red
  g : green
  b : blue
  a : alpha

// Convenience: opaque colour from 0..255 ints. Use sparingly — prefer
// passing typed components when you have them.
pub fun mk-rgb(rr : int, gg : int, bb : int) : exn rgba
  Rgba(mk-red(rr), mk-green(gg), mk-blue(bb), Alpha(255))

// Common solid colours (no validation needed; literals are in range).
pub val opaque-black : rgba = Rgba(Red(0),   Green(0),   Blue(0),   Alpha(255))
pub val opaque-white : rgba = Rgba(Red(255), Green(255), Blue(255), Alpha(255))
pub val transparent  : rgba = Rgba(Red(0),   Green(0),   Blue(0),   Alpha(0))
