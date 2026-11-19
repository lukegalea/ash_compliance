# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.StatusQuestionsTest do
  @moduledoc """
  A passed bundle is normalised to its stored spelling before evaluation, and
  `AshCompliance.Status.questions/2` turns an `:unknown` status into the
  absences a person must answer.

  Every status here is evaluated against a bundle passed through `:bundle`
  with explicit `:facts`, so nothing reads the database.
  """

  use ExUnit.Case, async: true

  alias AshCompliance.BundleForm
  alias AshCompliance.Status
  alias AshCompliance.Test.RuleSets.{AppointmentRules, QuestionRules}

  # --- normalising a passed bundle -------------------------------------------------

  describe "a bundle passed to status_for/2" do
    test "a DSL bundle evaluates exactly as its decoded form" do
      dsl = AppointmentRules.__bundle__()

      # String subjects, as the fact-builder contract emits them. Before
      # normalisation the DSL bundle's atom subject `:appointment` never met
      # them, and every rule read as not applicable.
      facts = [
        {"appointment", :transition_to, :checked_in},
        {"appointment", :patient_weight_recorded, false}
      ]

      assert {:ok, direct} = AshCompliance.status_for(:record, bundle: dsl, facts: facts)
      assert {:ok, stored} = AshCompliance.status_for(:record, bundle: decoded(dsl), facts: facts)

      assert direct.status == :noncompliant
      assert verdict(direct, "appt.checkin_requires_weight").status == :noncompliant
      assert direct == stored

      assert direct.bundle_hash == dsl.content_hash
      assert direct.bundle_revision == dsl.revision
    end

    test "normalising is idempotent and keeps the hash and the revision" do
      dsl = QuestionRules.__bundle__()
      stored = decoded(dsl)

      assert {:ok, ^stored} = BundleForm.normalize(dsl)
      assert {:ok, ^stored} = BundleForm.normalize(stored)

      assert stored.content_hash == dsl.content_hash
      assert stored.revision == dsl.revision
      assert stored.fact_schema_revision == dsl.fact_schema_revision
    end

    test "a bundle that cannot be normalised is an error, not a raise" do
      bundle = AppointmentRules.__bundle__()
      [rule | rest] = bundle.rules
      [predicate | predicates] = rule.applicability

      # A tuple has no JSON form.
      broken = %{
        bundle
        | rules: [
            %{rule | applicability: [%{predicate | value: {:no, :json}} | predicates]} | rest
          ]
      }

      assert {:error, {:invalid_bundle, _reason}} =
               AshCompliance.status_for(:record, bundle: broken, facts: [])

      assert {:error, {:invalid_bundle, _reason}} = BundleForm.normalize(broken)
    end
  end

  # --- questions/2 -----------------------------------------------------------------

  @application [{"application", :submitted, true}]
  @identity_checked [{"application", :identity_checked, true}]
  @references_checked [{"application", :references_checked, true}]

  @cases [
    %{
      name: "an unknown rule with an askable absence",
      facts: @application ++ @identity_checked,
      questions: [
        %{
          "rule" => "q.references_checked",
          "message" => "reference check outstanding",
          "evidence" => ["reference-letters"],
          "subject" => "application",
          "predicate" => "references_checked",
          "question" => "Have the applicant's references been checked?"
        }
      ]
    },
    %{
      # Both identity rules are unknown. The draft rule names the same fact
      # but is decided (not applicable) before it reaches it, so it asks
      # nothing. The two identity probes (`true` and `false`) leave two
      # absences for the same subject and predicate: one entry per rule, not
      # one per absence.
      name: "two unknown rules probing the same fact",
      facts: @application ++ @references_checked,
      questions: [
        %{
          "rule" => "q.identity_checked",
          "message" => "identity check outstanding",
          "evidence" => ["identity-record"],
          "subject" => "application",
          "predicate" => "identity_checked",
          "question" => "Has the applicant's identity been checked?"
        },
        %{
          "rule" => "q.identity_failed",
          "message" => "a failed identity check blocks the application",
          "evidence" => [],
          "subject" => "application",
          "predicate" => "identity_checked",
          "question" => "Has the applicant's identity been checked?"
        }
      ]
    },
    %{
      name: "a variable-subject probe",
      facts:
        @application ++
          @identity_checked ++
          @references_checked ++
          [
            {"doc-1", :attached_to, "application"},
            {"doc-2", :attached_to, "application"},
            {"doc-2", :signed, true},
            {"doc-3", :attached_to, "application"}
          ],
      questions:
        for subject <- ["doc-1", "doc-3"] do
          %{
            "rule" => "q.documents_signed",
            "message" => "a document is unsigned",
            "evidence" => ["signature"],
            "subject" => subject,
            "predicate" => "signed",
            "question" => "Has this document been signed?"
          }
        end
    },
    %{
      name: "no unknown rules",
      facts: @application ++ @identity_checked ++ @references_checked,
      questions: []
    }
  ]

  describe "questions/2" do
    for %{name: name} = example <- @cases do
      @example example
      test name do
        %{facts: facts, questions: questions} = @example

        status = status!(facts)

        assert {:ok, ^questions} = Status.questions(status, QuestionRules.__bundle__())
      end
    end

    test "an absence read as false asks nothing" do
      status = status!(@application ++ @identity_checked)

      # `fee_waived` was absent and probed, so it is reported missing; the
      # schema reads its absence as `false`, so nobody is asked for it.
      assert {"application", :fee_waived, false} in status.missing_facts

      assert {:ok, questions} = Status.questions(status, QuestionRules.__bundle__())
      refute Enum.any?(questions, &(&1["predicate"] == "fee_waived"))
    end

    test "an absence probed only by a decided rule asks nothing" do
      status = status!(@application ++ @references_checked)

      # questions/2 reads the status it is handed, as a host would hold a
      # stored one: the same absences, with the rules that probe them decided.
      decided = %{
        status
        | rules:
            Enum.map(status.rules, fn verdict ->
              if verdict.status == :unknown, do: %{verdict | status: :noncompliant}, else: verdict
            end)
      }

      assert Enum.any?(decided.missing_facts, &match?({_, :identity_checked, _}, &1))
      assert {:ok, []} = Status.questions(decided, QuestionRules.__bundle__())
    end

    test "an unknown rule with no askable absence gives [] and the status still blocks" do
      status = status!(@application ++ @identity_checked)
      assert verdict(status, "q.references_checked").status == :unknown

      # The same status without the absence the rule could ask about.
      unaskable = %{
        status
        | missing_facts:
            Enum.reject(status.missing_facts, &match?({_, :references_checked, _}, &1))
      }

      assert {:ok, []} = Status.questions(unaskable, QuestionRules.__bundle__())

      assert unaskable.status == :unknown
      assert verdict(unaskable, "q.references_checked").status == :unknown
      assert Status.message(unaskable) =~ "q.references_checked"
    end

    test "every bundle form gives the same questions" do
      status = status!(@application)
      dsl = QuestionRules.__bundle__()

      assert {:ok, questions} = Status.questions(status, dsl)
      assert {:ok, ^questions} = Status.questions(status, decoded(dsl))
      assert {:ok, ^questions} = AshCompliance.status_questions(status, dsl)

      assert Enum.map(questions, &{&1["rule"], &1["predicate"]}) == [
               {"q.identity_checked", "identity_checked"},
               {"q.identity_failed", "identity_checked"},
               {"q.references_checked", "references_checked"}
             ]
    end

    test "a bundle the status was not evaluated against is refused" do
      status = status!(@application)
      other = AppointmentRules.__bundle__()

      assert {:error, {:bundle_mismatch, status_hash, other_hash}} =
               Status.questions(status, other)

      assert status_hash == status.bundle_hash
      assert other_hash == other.content_hash
    end

    test "a bundle that is neither an IR bundle nor a PolicyBundle is refused" do
      status = status!(@application)

      assert {:error, {:invalid_bundle, :not_a_bundle}} =
               Status.questions(status, :not_a_bundle)
    end
  end

  # --- helpers -----------------------------------------------------------------------

  defp status!(facts) do
    {:ok, status} =
      AshCompliance.status_for(:record, bundle: QuestionRules.__bundle__(), facts: facts)

    status
  end

  defp decoded(bundle), do: bundle |> AshRules.Ir.encode!() |> AshRules.Ir.decode!()

  defp verdict(status, rule_id), do: Enum.find(status.rules, &(&1.rule_id == rule_id))
end
