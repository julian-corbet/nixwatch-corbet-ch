# An option nothing renders is never checked

**Finding:** in this module system, a required option with a constrained type is enforced only when
something FORCES it. An option that no rendered object reads — an estimate, an annotation, a number
kept for a report — can be omitted entirely, or given a value its own type forbids, and the whole
tree renders green. Neither the missing definition nor the type violation is an error until somebody
reads the value.

This was found the boring way: a check that was supposed to prove a trace store cannot keep zero
percent of the traffic reported that the declaration *rendered*. The option's type is a whole
percentage between 1 and 100. The value was 0. Nothing complained.

## Why

Two mechanisms compose into it, and each is reasonable alone.

**Option values are lazy.** `mkOption` with no default does not mean "must be defined"; it means
"has no value to fall back on if anybody asks". Type checking happens when the merged value is
forced. A growth term that only ever appears in a read-only report is forced when the report is read
— and rendering a manifest tree never reads the report.

**Only FAILING assertions have their messages forced.** The renderer collects assertions, filters to
the ones that are false, and formats only those into the failure text. This is exactly what the NixOS
module system does, and it is the right implementation. But it means the common advice — *write a
message that is a total function of the declaration, because messages are forced whether or not the
assertion holds* — is good advice for the wrong reason. A passing assertion's message is not
evaluated at all. Writing a total message is still correct, because a message that throws *in the
failing case* takes the evaluation down instead of reporting anything; it is simply not a way to
force anything.

The consequence is worth stating plainly: **you cannot force a value by mentioning it in an assertion
message.** It has to be in the assertion's own expression, or in something rendered.

## What shipped

An assertion per store that reads like a tautology and is not:

```nix
assertion = growthOf x != "";
```

`growthOf` reads the store's growth term, which forces it. Forcing it does two things at once: a
store declared without one now fails the render ("used but not defined") instead of quietly omitting
what it costs, and a value its type forbids now fails the render instead of only failing a report
nobody built.

The comment above it in `modules/cluster.nix` is longer than the assertion, deliberately. An
assertion that exists for what it FORCES rather than for what it COMPARES is exactly the kind of line
a later reader deletes as dead code, and the check that would have caught the deletion is the one
this study came from.

## The general shape, for the next module in this family

Ask, for every option with no default or a constrained type: **what forces this?**

- If a rendered object reads it, nothing more is needed — the render forces it.
- If only a read-only report reads it, it is currently optional and unchecked, whatever its type
  says. Either force it from an assertion's expression, or stop claiming it is required.
- Never rely on an assertion's message to force anything.

And in the checks: a case asserting that a bad VALUE is refused must force the same thing a real
consumer forces. This repository's cluster checks call the refusal proven when
`environmentPackage.drvPath` cannot be evaluated — which is what a consumer actually builds. Had the
check instead read the report, it would have passed while the render stayed broken, which is the
same class of green-but-tested-nothing that this repository's CI file already refuses for
`--all-systems`.

## A postscript about how conventions travel

The commit that introduced this study also shipped, in `modules/cluster.nix`, the exact sentence the
study disproves: that an assertion's message is forced whether or not the assertion holds. It was in
the house comment block every cluster module in the family carries, it was copied in with the block,
and it survived being written directly above the assertion that only exists because it is false.

That is the sharper lesson, and it is not about laziness. A finding arrives as one specific thing you
now know; a convention arrives as a whole shape you reach for without re-deriving it. The two were in
the same file, minutes apart, and the convention won — because nothing in the act of copying a
template asks whether the template is still true.

So the rule is narrow and mechanical: **when a finding contradicts a sentence you are about to copy,
the copy is the thing that has to change, in the same commit.** Not filed for later, because the
version that ships is the one the next repository is scaffolded from. Six sibling repositories had
already taken this sentence from `nixk3s/modules/addressing/default.nix` before anybody noticed, and
it had to be corrected in all seven.
