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
    test "requires message_id and user_id" do
      cs = DeliveryStatus.changeset(%DeliveryStatus{}, %{})
      refute cs.valid?
      errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
      assert errors[:message_id] |> List.wrap() |> Enum.any?(&(&1 =~ "blank"))
      assert errors[:user_id] |> List.wrap() |> Enum.any?(&(&1 =~ "blank"))
    end

    test "accepts a valid input" do
      cs =
        DeliveryStatus.changeset(%DeliveryStatus{}, %{
          message_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate()
        })

      assert cs.valid?
    end
  end

  describe "mark_delivered_changeset/2" do
    test "uses provided timestamp" do
      ts = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      cs = DeliveryStatus.mark_delivered_changeset(%DeliveryStatus{}, ts)
      assert Ecto.Changeset.get_field(cs, :delivered_at) == ts
    end

    test "defaults to now when no timestamp is given" do
      cs = DeliveryStatus.mark_delivered_changeset(%DeliveryStatus{})
      assert %DateTime{} = Ecto.Changeset.get_field(cs, :delivered_at)
    end
  end

  describe "mark_read_changeset/2" do
    test "sets read_at and back-fills delivered_at when missing" do
      ts = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)
      cs = DeliveryStatus.mark_read_changeset(%DeliveryStatus{}, ts)

      assert Ecto.Changeset.get_field(cs, :read_at) == ts
      assert Ecto.Changeset.get_field(cs, :delivered_at) == ts
    end

    test "preserves an existing delivered_at when present" do
      existing = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      new = DateTime.utc_now() |> DateTime.truncate(:second)

      cs =
        DeliveryStatus.mark_read_changeset(
          %DeliveryStatus{delivered_at: existing},
          new
        )

      assert Ecto.Changeset.get_field(cs, :read_at) == new
      assert Ecto.Changeset.get_field(cs, :delivered_at) == existing
    end
  end

  describe "delivered?/1 and read?/1" do
    test "delivered? returns true only when delivered_at is set" do
      assert DeliveryStatus.delivered?(%DeliveryStatus{delivered_at: DateTime.utc_now()})
      refute DeliveryStatus.delivered?(%DeliveryStatus{delivered_at: nil})
    end

    test "read? returns true only when read_at is set" do
      assert DeliveryStatus.read?(%DeliveryStatus{read_at: DateTime.utc_now()})
      refute DeliveryStatus.read?(%DeliveryStatus{read_at: nil})
    end
  end

  describe "duration helpers" do
    test "delivery_duration_ms returns nil when not delivered" do
      sent_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert DeliveryStatus.delivery_duration_ms(%DeliveryStatus{delivered_at: nil}, sent_at) ==
               nil
    end

    test "delivery_duration_ms returns the difference in ms" do
      sent_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      delivered_at = DateTime.utc_now() |> DateTime.truncate(:second)

      diff =
        DeliveryStatus.delivery_duration_ms(
          %DeliveryStatus{delivered_at: delivered_at},
          sent_at
        )

      assert is_integer(diff) and diff >= 0
    end

    test "read_duration_ms returns nil when not read" do
      sent_at = DateTime.utc_now() |> DateTime.truncate(:second)
      assert DeliveryStatus.read_duration_ms(%DeliveryStatus{read_at: nil}, sent_at) == nil
    end

    test "read_duration_ms returns the difference in ms" do
      sent_at = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
      read_at = DateTime.utc_now() |> DateTime.truncate(:second)

      diff = DeliveryStatus.read_duration_ms(%DeliveryStatus{read_at: read_at}, sent_at)
      assert is_integer(diff) and diff >= 0
    end
  end

  describe "create_delivery_status/2" do
    test "returns a valid changeset" do
      cs = DeliveryStatus.create_delivery_status(Ecto.UUID.generate(), Ecto.UUID.generate())
      assert %Ecto.Changeset{} = cs
      assert cs.valid?
    end
  end
end
