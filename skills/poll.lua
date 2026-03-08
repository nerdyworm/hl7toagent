return {
    run = function()
        return "Patient: Testing Smith\nDiagnosis: OK\nBilling Status: PAID"
        -- local resp = http.get("https://api.lab.com/results?status=new")
        -- if resp.status == 200 then
        --     return resp.body       -- forwarded to channel
        -- end
        -- return nil                 -- nothing this cycle
    end
}
