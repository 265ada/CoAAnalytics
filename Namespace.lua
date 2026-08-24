local ADDON_NAME = ...

CoAAnalyticsAddon = CoAAnalyticsAddon or {}
local Addon = CoAAnalyticsAddon

Addon.NAME = ADDON_NAME or "CoAAnalytics"
Addon.VERSION = "2.15.0"
Addon.Modules = Addon.Modules or {}

Addon.Events = Addon.Events or { listeners = {} }
local Events = Addon.Events

function Events:Register(eventName, callback)
	if type(eventName) ~= "string" or type(callback) ~= "function" then
		return
	end
	local listeners = self.listeners[eventName]
	if not listeners then
		listeners = {}
		self.listeners[eventName] = listeners
	end
	listeners[#listeners + 1] = callback
end

function Events:Fire(eventName, ...)
	local listeners = self.listeners[eventName]
	if not listeners then
		return
	end
	for index = 1, #listeners do
		local ok, errorMessage = pcall(listeners[index], ...)
		if not ok and DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cffff5050CoA Analytics: module error "
					.. tostring(eventName) .. " - " .. tostring(errorMessage) .. "|r"
			)
		end
	end
end

CoAAnalyticsAPI = CoAAnalyticsAPI or {}
Addon.API = CoAAnalyticsAPI
