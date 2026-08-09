## An associative merge `⊕` with the properties a transport is allowed to assume.
##
## Under the Cell kernel a "merge cell" is not a distinct node kind — it is a
## [LazilySource] whose policy is something other than [method keep_latest]. The
## identity `Source ≡ Source<KeepLatest>` is a default, not a special case, which
## is why [method LazilyContext.source] and [method LazilyContext.source_with]
## build the same class.
##
## The flags are declared rather than derived because no runtime check can
## establish them: they are claims about the fold for all inputs, and a transport
## that skips a redelivery because [member idempotent] is true is trusting the
## claim. `mergecell_algebra.json` asserts them against the policy, so a policy
## that lies fails the corpus rather than silently corrupting a replay.
class_name LazilyMergePolicy
extends RefCounted

## Short name, matching the corpus spelling (`KeepLatest`, `Sum`, …).
var policy_name: String

## `a ⊕ b = b ⊕ a`. Lets a transport deliver out of order.
var commutative: bool

## `a ⊕ a = a`. Lets a transport redeliver without changing the result.
var idempotent: bool

var _fold: Callable


func _init(name: String, fold: Callable, is_commutative: bool, is_idempotent: bool) -> void:
	policy_name = name
	_fold = fold
	commutative = is_commutative
	idempotent = is_idempotent


## Fold `op` into `current`.
func merge(current: Variant, op: Variant) -> Variant:
	return _fold.call(current, op)


## Last write wins — the plain cell. Idempotent and NOT commutative: replaying
## two different writes in the other order lands on the other value.
static func keep_latest() -> LazilyMergePolicy:
	return LazilyMergePolicy.new(
		"KeepLatest", func(_cur: Variant, op: Variant) -> Variant: return op, false, true
	)


## Numeric addition — the accumulator. Commutative and NOT idempotent, which is
## what makes it the policy the corpus folds with: a binding that folded once
## where the caller called three times lands on a different NUMBER, not merely a
## different count.
static func sum() -> LazilyMergePolicy:
	return LazilyMergePolicy.new(
		"Sum", func(cur: Variant, op: Variant) -> Variant: return cur + op, true, false
	)
