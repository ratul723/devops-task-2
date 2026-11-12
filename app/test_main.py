def test_fault_injection_disabled_by_default():
    assert client.get("/boom").status_code == 404