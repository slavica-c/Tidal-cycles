# TidalCycles log of changes

## 0.9.5

### Enhancements

* Added `hurry` which both speeds up the sound and the pattern by the given amount.
* Added `stripe` which repeats a pattern a given number of times per
  cycle, with random but contiguous durations.
* Added continuous function `cosine`

## 0.9.4

### Fixes

* Swapped `-` for `..` in ranges as quick fix for issue with parsing negative numbers
* Removed overloaded list thingie for now, unsure whether it's worth the dependency

## 0.9.3

### Enhancements

* The sequence parser can now expand ranges, e.g. `"0-3 4-2"` is
  equivalent to `"[0 1 2 3] [4 3 2]"`
* Sequences can now be described using list syntax, for example `sound ["bd", "sn"]` is equivalent to `sound "bd sn"`. They *aren't* lists though, so you can't for example do `sound (["bd", "sn"] ++ ["arpy", "cp"])` -- but can do `sound (append ["bd", "sn"]  ["arpy", "cp"])`
* New function `linger`, e.g. `linger (1/4)` will only play the first quarter of the given pattern, four times to fill the cycle. 
* `discretise` now takes time value as its first parameter, not a pattern of time, which was causing problems and needs some careful thought.
* a `rel` alias for the `release` parameter, to match the `att` alias for `attack`
* `_fast` alias for `_density`
* The start of automatic testing for a holy bug-free future

### Fixes

* Fixed bug that was causing events to double up or get lost,
  e.g. where `rev` was combined with certain other functions.
