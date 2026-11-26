From Coq Require Import ZArith List Lia.
Require Import Portfolio.
Import ListNotations.
Local Open Scope Z_scope.

Definition week : Z := 604800.
Definition monday_offset : Z := 345600.
Definition week_index t := (t - monday_offset) / week.
Definition aligned expiry := exists k, expiry = monday_offset + k * week.
Definition active expiry t := andb (t <? expiry) (expiry - t <=? horizon).

Fixpoint active_principal (p : portfolio) t : Z :=
  match p with
  | [] => 0
  | (amount, expiry) :: rest =>
      (if active expiry t then amount else 0) + active_principal rest t
  end.

(* No weekly boundary can occur strictly after the first timestamp and at or
   before the second. Both ends of every decay interval are weekly boundaries. *)
Lemma week_contains t :
  monday_offset + week_index t * week <= t <
  monday_offset + (week_index t + 1) * week.
Proof.
  unfold week_index, monday_offset, week.
  pose proof (Z.div_mod (t - 345600) 604800 ltac:(lia)).
  pose proof (Z.mod_pos_bound (t - 345600) 604800 ltac:(lia)). lia.
Qed.

Lemma weekly_overlap expiry t0 t1 :
  aligned expiry -> t0 <= t1 -> week_index t0 = week_index t1 ->
  overlap expiry t0 t1 = if active expiry t0 then t1 - t0 else 0.
Proof.
  intros [k ->] Order Same.
  pose proof (week_contains t0) as First. pose proof (week_contains t1) as Last.
  rewrite <- Same in Last.
  unfold overlap, active, monday_offset, week, horizon in *.
  destruct (t0 <? 345600 + k * 604800) eqn:Past;
    destruct (345600 + k * 604800 - t0 <=? 94348800) eqn:Cap;
    try apply Z.ltb_lt in Past; try apply Z.ltb_ge in Past;
    try apply Z.leb_le in Cap; try apply Z.leb_gt in Cap;
    simpl andb; repeat match goal with
    | |- context [Z.max ?a ?b] => destruct (Z.max_spec a b) as [[? ->]|[? ->]]
    | |- context [Z.min ?a ?b] => destruct (Z.min_spec a b) as [[? ->]|[? ->]]
    end; lia.
Qed.

(* This is the dense Locker's same-week shortcut: using the active amount at
   t0 has exactly the same effect as repricing every ordinary position at t1. *)
Theorem same_week_fast_path p t0 t1 :
  Forall (fun entry => aligned (snd entry)) p ->
  t0 <= t1 -> week_index t0 = week_index t1 ->
  numerator p t1 = numerator p t0 - 9 * active_principal p t0 * (t1 - t0).
Proof.
  intros Aligned Order Same.
  pose proof (portfolio_exact_loss p t0 t1 Order) as Loss.
  enough (exposure p t0 t1 = active_principal p t0 * (t1 - t0)) by lia.
  clear Loss. induction Aligned as [|[a e] rest Align _ IH].
  - reflexivity.
  - cbn [exposure active_principal]. rewrite weekly_overlap by assumption.
    destruct (active e t0); rewrite IH; ring.
Qed.

Fixpoint principal (p : portfolio) : Z :=
  match p with [] => 0 | (a, _) :: rest => a + principal rest end.

Lemma numerator_bounds p t :
  Forall (fun entry => 0 <= fst entry) p ->
  horizon * principal p <= numerator p t <= 10 * horizon * principal p.
Proof.
  induction 1 as [|[a e] rest A _ IH].
  - cbn [principal numerator]. lia.
  - cbn [fst] in A. cbn [principal numerator].
    assert (Range : horizon <= weight e t <= 10 * horizon).
    { unfold weight. pose proof horizon_positive.
      pose proof (Z.le_min_l horizon (Z.max 0 (e-t))).
      pose proof (Z.le_max_l 0 (e-t)).
      assert (0 <= Z.min horizon (Z.max 0 (e-t))) by (apply Z.min_glb; lia).
      lia. }
    nia.
Qed.

(* For an admitted ordinary principal the u128 numerator and both narrowed
   head fields fit. This includes a portfolio exactly at the principal cap. *)
Theorem head_fields_fit p t :
  Forall (fun entry => 0 <= fst entry) p ->
  principal p <= 1000000000000000000 ->
  let n := numerator p t in
  0 <= n < 2^128 /\ 0 <= n / horizon < 2^64 /\
  0 <= n mod horizon < 2^32.
Proof.
  intros Positive Cap. pose proof (numerator_bounds p t Positive) as Bounds.
  assert (Nonnegative : 0 <= principal p).
  { clear Cap Bounds. induction Positive as [|[a e] rest A _ IH]; cbn [principal fst] in *; lia. }
  cbn zeta. pose proof (Z.mod_pos_bound (numerator p t) horizon horizon_positive).
  pose proof (Z.div_mod (numerator p t) horizon ltac:(pose proof horizon_positive; lia)).
  unfold horizon in *. change (2^128) with 340282366920938463463374607431768211456.
  change (2^64) with 18446744073709551616. change (2^32) with 4294967296. lia.
Qed.

(* The two update strategies used by the dense head. When the week changes,
   rebuild the numerator from all ordinary buckets. Within a week, update
   the previous head using only its carried remainder and active principal. *)
Definition advance_head p from target head :=
  if Z.eqb (week_index from) (week_index target)
  then encode (decode head - 9 * active_principal p from * (target - from))
  else encode (numerator p target).

Fixpoint advance_many p from head (times : list Z) :=
  match times with
  | [] => head
  | target :: next =>
      advance_many p target (advance_head p from target head) next
  end.

Theorem dense_checkpoints_equal_reprice p times from :
  Forall (fun entry => aligned (snd entry)) p -> ordered_from from times ->
  advance_many p from (encode (numerator p from)) times =
    encode (numerator p (final_time from times)).
Proof.
  intros Aligned. revert from.
  induction times as [|target next IH]; intros from Ordered; [reflexivity|].
  destruct Ordered as [Order Later]. cbn [advance_many final_time].
  unfold advance_head. destruct (Z.eqb (week_index from) (week_index target)) eqn:Same.
  - apply Z.eqb_eq in Same.
    rewrite decode_encode, <- (same_week_fast_path p from target Aligned Order Same).
    apply IH, Later.
  - apply IH, Later.
Qed.

Corollary elapsed_time_cannot_increase_whole_power p t0 t1 :
  Forall (fun entry => 0 <= fst entry) p -> t0 <= t1 ->
  fst (encode (numerator p t1)) <= fst (encode (numerator p t0)).
Proof.
  intros Amounts Ordered. unfold encode. cbn [fst].
  apply Z.div_le_mono; [exact horizon_positive | now apply numerator_monotone].
Qed.
