defmodule WhisprMessaging.Messages.DeliveryStatusTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.DeliveryStatus

  describe "compute_status/1" do
    test "returns 'pending' when neither delivered nor read" do
      status = %DeliveryStatus{delivered_at: nil, read_at: nil}
      assert DeliveryStatus.compute_status(status) == "pending"
    end

    test "returns 'delivered' when delivered but not read" do
      status = %DeliveryStatus{
        delivered_at: DateTime.utc_now(),
        read_at: nil
      }

      assert DeliveryStatus.compute_status(status) == "delivered"
    end

    test "returns 'read' when both delivered and read" do
      now = DateTime.utc_now()

      status = %DeliveryStatus{
        delivered_at: now,
        read_at: now
      }

      assert DeliveryStatus.compute_status(status) == "read"
    end

    test "returns 'read' when read_at is set even if delivered_at is nil" do
      # This can happen when mark_read is called without prior mark_delivered
      status = %DeliveryStatus{
        delivered_at: nil,
        read_at: DateTime.utc_now()
      }

      assert DeliveryStatus.compute_status(status) == "read"
    end
  end

  describe "compute_aggregate_status/1" do
    test "returns 'sent' for empty list" do
      assert DeliveryStatus.compute_aggregate_status([]) == "sent"
    end

    test "returns 'pending' when any recipient is pending" do
      statuses = [
        %DeliveryStatus{delivered_at: DateTime.utc_now(), read_at: nil},
        %DeliveryStatus{delivered_at: nil, read_at: nil}
      ]

      assert DeliveryStatus.compute_aggregate_status(statuses) == "pending"
    end

    test "returns 'delivered' when all are delivered but not all read" do
      now = DateTime.utc_now()

      statuses = [
        %DeliveryStatus{delivered_at: now, read_at: now},
        %DeliveryStatus{delivered_at: now, read_at: nil}
      ]

      assert DeliveryStatus.compute_aggregate_status(statuses) == "delivered"
    end

    test "returns 'read' when all recipients have read" do
      now = DateTime.utc_now()

      statuses = [
        %DeliveryStatus{delivered_at: now, read_at: now},
        %DeliveryStatus{delivered_at: now, read_at: now}
      ]

      assert DeliveryStatus.compute_aggregate_status(statuses) == "read"
    end

    test "returns 'pending' for single pending recipient" do
      statuses = [%DeliveryStatus{delivered_at: nil, read_at: nil}]
      assert DeliveryStatus.compute_aggregate_status(statuses) == "pending"
    end

    test "returns 'delivered' for single delivered recipient" do
      statuses = [
        %DeliveryStatus{delivered_at: DateTime.utc_now(), read_at: nil}
      ]

      assert DeliveryStatus.compute_aggregate_status(statuses) == "delivered"
    end

    test "returns 'read' for single read recipient" do
      now = DateTime.utc_now()
      statuses = [%DeliveryStatus{delivered_at: now, read_at: now}]
      assert DeliveryStatus.compute_aggregate_status(statuses) == "read"
    end
  end

  describe "changeset/2" do
    test "is valid with required fields" do
      cs =
        DeliveryStatus.changeset(%DeliveryStatus{}, %{
          message_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate()
        })

      assert cs.valid?
    end

    test "is invalid when required fields are missing" do
      cs = DeliveryStatus.changeset(%DeliveryStatus{}, %{})
      refute cs.valid?
    end
  end

  describe "mark_delivered_changeset/2" do
    test "uses the provided timestamp" do
      ts = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      cs = DeliveryStatus.mark_delivered_changeset(%DeliveryStatus{}, ts)
      assert cs.changes.delivered_at == ts
    end

    test "defaults to now when no timestamp is given" do
      cs = DeliveryStatus.mark_delivered_changeset(%DeliveryStatus{})
      assert %DateTime{} = cs.changes.delivered_at
    end
  end

  describe "mark_read_changeset/2" do
    test "back-fills delivered_at when missing" do
      cs = DeliveryStatus.mark_read_changeset(%DeliveryStatus{delivered_at: nil})
      assert %DateTime{} = cs.changes.read_at
      assert %DateTime{} = cs.changes.delivered_at
    end

    test "leaves an existing delivered_at intact" do
      old =
        DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      cs = DeliveryStatus.mark_read_changeset(%DeliveryStatus{delivered_at: old})
      assert cs.changes.read_at != nil
      refute Map.has_key?(cs.changes, :delivered_at)
    end
  end

  describe "queries" do
    test "by_message_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = DeliveryStatus.by_message_query(Ecto.UUID.generate())
    end

    test "by_message_and_user_query/2 returns an Ecto.Query" do
      assert %Ecto.Query{} =
               DeliveryStatus.by_message_and_user_query(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate()
               )
    end

    test "undelivered_for_user_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = DeliveryStatus.undelivered_for_user_query(Ecto.UUID.generate())
    end

    test "unread_for_user_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = DeliveryStatus.unread_for_user_query(Ecto.UUID.generate())
    end

    test "read_receipt_summary_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = DeliveryStatus.read_receipt_summary_query(Ecto.UUID.generate())
    end
  end

  describe "predicates" do
    test "delivered? mirrors delivered_at" do
      refute DeliveryStatus.delivered?(%DeliveryStatus{delivered_at: nil})
      assert DeliveryStatus.delivered?(%DeliveryStatus{delivered_at: DateTime.utc_now()})
    end

    test "read? mirrors read_at" do
      refute DeliveryStatus.read?(%DeliveryStatus{read_at: nil})
      assert DeliveryStatus.read?(%DeliveryStatus{read_at: DateTime.utc_now()})
    end
  end

  describe "duration helpers" do
    test "delivery_duration_ms returns nil when not delivered" do
      assert nil ==
               DeliveryStatus.delivery_duration_ms(%DeliveryStatus{}, DateTime.utc_now())
    end

    test "delivery_duration_ms returns the difference in ms" do
      sent = DateTime.utc_now() |> DateTime.add(-1, :second)

      duration =
        DeliveryStatus.delivery_duration_ms(
          %DeliveryStatus{delivered_at: DateTime.utc_now()},
          sent
        )

      assert duration >= 0
    end

    test "read_duration_ms returns nil when not read" do
      assert nil == DeliveryStatus.read_duration_ms(%DeliveryStatus{}, DateTime.utc_now())
    end

    test "read_duration_ms returns the difference in ms" do
      sent = DateTime.utc_now() |> DateTime.add(-2, :second)

      duration =
        DeliveryStatus.read_duration_ms(
          %DeliveryStatus{read_at: DateTime.utc_now()},
          sent
        )

      assert duration >= 0
    end
  end

  describe "create_*" do
    test "create_delivery_status returns a valid changeset" do
      cs = DeliveryStatus.create_delivery_status(Ecto.UUID.generate(), Ecto.UUID.generate())
      assert cs.valid?
    end

    test "create_for_conversation_members returns the expected SQL string" do
      sql =
        DeliveryStatus.create_for_conversation_members(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          Ecto.UUID.generate()
        )

      assert is_binary(sql)
      assert String.contains?(sql, "INSERT INTO delivery_statuses")
    end
  end
end
