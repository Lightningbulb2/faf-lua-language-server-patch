local Window = import("/lua/maui/window.lua").Window

---@class TestIface : Window
TestIface = ClassUI(Window) {
    ---@param self TestIface
    ---@param parent Control
    __init = function(self, parent)
        Window.__init(self, parent, "test")
        self:SetupThing()
    end,

    ---@param self TestIface
    SetupThing = function(self)
    end,

    ---@param self TestIface
    HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' then
            self.StartSizing(event, true, true)
            self._sizeLock = true
        end
    end,
}
