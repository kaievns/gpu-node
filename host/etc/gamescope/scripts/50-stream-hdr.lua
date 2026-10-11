-- SDR unless stream-hdr wrote "hdr" to ~/.config/gamescope/hdr. See docs/streaming.md §8.
local state_file = os.getenv("HOME") .. "/.config/gamescope/hdr"

local function hdr_wanted()
    local f = io.open(state_file, "r")
    if not f then
        return false
    end
    local v = f:read("*l")
    f:close()
    return v == "hdr"
end

gamescope.config.known_displays.stream_sdr = {
    pretty_name = "Stream output (SDR, stream-hdr)",
    hdr = {
        supported = false,
        force_enabled = false,
        eotf = gamescope.eotf.gamma22,
    },
    matches = function(display)
        if hdr_wanted() then
            return -1
        end
        return 10000
    end
}
