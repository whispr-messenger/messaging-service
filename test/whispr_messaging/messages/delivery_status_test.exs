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
end
