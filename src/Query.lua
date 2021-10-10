
local QueryResult = require("QueryResult")

--[[
   Global cache result.

   The validated components are always the same (reference in memory, except within the archetypes),
   in this way, you can save the result of a query in an archetype, reducing the overall execution
   time (since we don't need to iterate all the time)

   @type KEY string = concat(Array<ComponentClass.Id>, "_")
   @Type {
      [Archetype] = {
         Any  = { [KEY] = bool },
         All  = { [KEY] = bool },
         None = { [KEY] = bool },
      }
   }
]]
local CACHE = {}

--[[
   Interface for creating filters for existing entities in the ECS world
]]
local Query = {}
Query.__index = Query
setmetatable(Query, {
   __call = function(t, all, any, none)
      return Query.New(all, any, none)
   end,
})

local function parseFilters(list, clauseGroup, clauses)
   local indexed = {}
   local cTypes = {}
   local cTypeIds = {}
   
   for i,item in ipairs(list) do
      if (indexed[item] == nil) then
         if (item.IsCType and not item.IsComponent) then
            indexed[item] = true
            table.insert(cTypes, item)
            table.insert(cTypeIds, item.Id)
         else
            if item.Components then
               indexed[item] = true   
               for _,cType in ipairs(item.Components) do
                  if (not indexed[cType] and cType.IsCType and not cType.IsComponent) then
                     indexed[cType] = true
                     table.insert(cTypes, cType)
                     table.insert(cTypeIds, item.Id)
                  end
               end
            end   

            -- clauses
            if item.Filter then
               indexed[item] = true
               item[clauseGroup] = true
               table.insert(clauses, item)
            end
         end
      end
   end

   if #cTypes > 0 then
      table.sort(cTypeIds)
      local cTypesKey = '_' .. table.concat(cTypeIds, '_')   
      return cTypes, cTypesKey
   end
end

--[[
   Generate a function responsible for performing the filter on a list of components.
   It makes use of local and global cache in order to decrease the validation time (avoids looping in runtime of systems)

   ECS.Query.All({ Movement.In("Standing") })

   @param all {Array<ComponentClass|Clause>[]} All component types in this array must exist in the archetype
   @param any {Array<ComponentClass|Clause>[]} At least one of the component types in this array must exist in the archetype
   @param none {Array<ComponentClass|Clause>[]} None of the component types in this array can exist in the archetype
]]
function Query.New(all, any, none)

   -- used by QueryResult
   local clauses = {}

   local anyKey, allKey, noneKey

   if (any ~= nil) then
      any, anyKey = parseFilters(any, "IsAnyFilter", clauses)
   end

   if (all ~= nil) then
      all, allKey = parseFilters(all, "IsAllFilter", clauses)
   end

   if (none ~= nil) then
      none, noneKey = parseFilters(none, "IsNoneFilter", clauses)
   end

   return setmetatable({
      IsQuery = true,
      _Any = any,
      _All = all,
      _None = none,
      _AnyKey = anyKey,
      _AllKey = allKey,
      _NoneKey = noneKey,
      _Cache = {}, -- local cache (L1)
      _Clauses = #clauses > 0 and clauses or nil,
   }, Query)
end

--[[
   Generate a QueryResult with the chunks entered and the clauses of the current query

   @param chunks {Chunk}
   @return QueryResult
]]
function Query:Result(chunks)
   return QueryResult.New(chunks, self._Clauses)
end

--[[
   Checks if the entered archetype is valid by the query definition

   @param archetype {Archetype}
   @return bool
]]
function Query:Match(archetype)

   -- cache L1
   local localCache = self._Cache
   
   -- check local cache (L1)
   local cacheResult = localCache[archetype]
   if cacheResult ~= nil then
      return cacheResult
   else
      -- check global cache (executed by other filter instance)
      local globalCache = CACHE[archetype]
      if (globalCache == nil) then
         globalCache = { Any = {}, All = {}, None = {} }
         CACHE[archetype] = globalCache
      end
      
      -- check if these combinations exist in this component array

      local noneKey = self._NoneKey
      if noneKey then
         local isNoneValid = globalCache.None[noneKey]
         if (isNoneValid == nil) then
            isNoneValid = true
            for _, cType in ipairs(self._None) do
               if archetype:Has(cType) then
                  isNoneValid = false
                  break
               end
            end
            globalCache.None[noneKey] = isNoneValid
         end

         if (isNoneValid == false) then
            localCache[archetype] = false
            return false
         end     
      end

      local anyKey = self._AnyKey
      if anyKey then
         local isAnyValid = globalCache.Any[anyKey]
         if (isAnyValid == nil) then
            isAnyValid = false
            if (globalCache.All[anyKey] == true) then
               isAnyValid = true
            else
               for _, cType in ipairs(self._Any) do
                  if archetype:Has(cType) then
                     isAnyValid = true
                     break
                  end
               end
            end
            globalCache.Any[anyKey] = isAnyValid
         end

         if (isAnyValid == false) then
            localCache[archetype] = false
            return false
         end
      end

      local allKey = self._AllKey
      if allKey then
         local isAllValid = globalCache.All[allKey]
         if (isAllValid == nil) then
            local haveAll = true
            for _, cType in ipairs(self._All) do
               if (not archetype:Has(cType)) then
                  haveAll = false
                  break
               end
            end

            if haveAll then
               isAllValid = true
            else
               isAllValid = false
            end

            globalCache.All[allKey] = isAllValid
         end

         localCache[archetype] = isAllValid
         return isAllValid
      end

      -- empty query = SELECT * FROM
      localCache[archetype] = true
      return true
   end
end

local function builder()
   local builder = {
      IsQueryBuilder = true
   }

   function builder.All(items)
      builder._All = items
      return builder
   end
   
   function builder.Any(items)
      builder._Any = items
      return builder
   end
   
   function builder.None(items)
      builder._None = items
      return builder
   end

   function builder.Build()
      return Query.New(builder._All, builder._Any, builder._None)
   end

   return builder
end

function Query.All(items)
   return builder().All(items)
end

function Query.Any(items)
   return builder().Any(items)
end

function Query.None(items)
   return builder().None(items)
end

return Query
