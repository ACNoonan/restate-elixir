defmodule Restate.TestHarnessTest do
  use ExUnit.Case, async: false

  alias Restate.TestHarness
  alias Restate.TestHarness.Instance

  @moduletag :integration

  describe "lifecycle" do
    test "start_link boots a healthy restate-server and stops cleanly" do
      {:ok, harness} = TestHarness.start_link(health_timeout_ms: 60_000)
      instance = TestHarness.info(harness)

      assert %Instance{} = instance
      assert :ok = TestHarness.health(instance)
      assert instance.ingress_url =~ "http://localhost:"
      assert instance.admin_url =~ "http://localhost:"

      :ok = TestHarness.stop(harness)

      assert {:error, _} = TestHarness.health(instance)
    end

    test "register_deployment succeeds against a freshly booted server" do
      {:ok, harness} = TestHarness.start_link(health_timeout_ms: 60_000)
      instance = TestHarness.info(harness)

      bad_uri = "http://host.docker.internal:1"

      assert {:error, {:http, status, _}} =
               TestHarness.register_deployment(instance, uri: bad_uri, use_http_11: true)

      assert status in 400..599

      :ok = TestHarness.stop(harness)
    end
  end
end
