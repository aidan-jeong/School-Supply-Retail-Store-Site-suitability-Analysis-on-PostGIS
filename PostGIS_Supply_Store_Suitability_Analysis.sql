-- 1. Creating Temporary Table of Business Directories to Avoid (Competitors)
CREATE TEMPORARY TABLE avoid AS
    SELECT * 
    FROM business.businesses
    WHERE naicsdescr ILIKE '%general merchandise%'
    OR naicsdescr ILIKE '%Office Supplies%';

-- 1-2. 1km Buffering Avoidable Business Locations
CREATE TEMPORARY TABLE temp_buffered AS
    SELECT gid, 
           "name", 
           ST_Buffer(geom, 1000) AS buffered_geom 
    FROM avoid;

-- 1-3. Unify Buffers into One
CREATE TEMPORARY TABLE unified_buffer AS
    SELECT ST_Union(buffered_geom) AS unified_geom
    FROM temp_buffered;

-- 2. Unique Vacant Land that are within 500m from School
CREATE TEMPORARY TABLE near_school AS
    SELECT DISTINCT l1.gid AS gid, 
    l1.landuse AS landuse, 
    l1.geom AS geom
    FROM landuse.landuses l1 
    INNER JOIN landuse.landuses l2 
    ON ST_DWithin(l1.geom, l2.geom, 500) 
    WHERE l1.landuse = 'Vacant' AND l2.landuse = 'School';

-- 3. Vacants NOT Within Unified Buffer + Adding Area Size Column
CREATE TEMPORARY TABLE out_buffer AS
    SELECT *,
           ST_Area(near_school.geom) AS AREA_SQM,
           ST_AREA(near_school.geom)/4046.85642 AS AREA_ACRE
    FROM near_school
    LEFT JOIN unified_buffer ub
    ON ST_Within(near_school.geom, ub.unified_geom)
    WHERE ub.unified_geom IS NULL;


-- 4. Distancing from Watercourses for Potential Flood Extent

-- 4-1. 300m Buffering from Watercourses
CREATE TEMPORARY TABLE water_buffer_indiv AS
    SELECT gid, 
           "type", 
           ST_Buffer(geom, 300) AS buffered_geom 
    FROM watercourse.watercourses
    WHERE mun_name = 'Mississauga';

-- 4-2. Unify Buffers into One
CREATE TEMPORARY TABLE unified_water_buffer AS
    SELECT ST_Union(buffered_geom) AS unified_water_geom
    FROM water_buffer_indiv;

-- 4-3. Sort Out Filetered Vacant Land from Unified Water Buffer
CREATE TEMPORARY TABLE flood_safe AS
    SELECT *
    FROM out_buffer ob
    LEFT JOIN unified_water_buffer uw
    ON ST_Within(ob.geom, uw.unified_water_geom)
    WHERE uw.unified_water_geom IS NULL;

SELECT * FROM flood_safe;

-- 5. Slope Limiting
-- 5.1 Something you want to add
CREATE TEMPORARY TABLE temp_summary AS
	SELECT fls.gid AS gid,  
		   (ST_SummaryStats(s.rast)).mean AS mean,
		   fls.geom AS geom,
		   fls.area_sqm AS area_sqm,
		   fls.area_acre AS area_acre
	FROM flood_safe AS fls
	INNER JOIN slope.slopes AS s 
	ON ST_Intersects(fls.geom, s.rast);

-- 5.2 Averaging Slope Values Out to Each GID
CREATE TEMPORARY TABLE slope_calculated AS
	SELECT gid,
	       AVG(mean) AS average
	FROM temp_summary 
	GROUP BY gid;


-- 5.3 Join Tables to Insert Average Slope Value per GID
CREATE TEMPORARY TABLE slope_satisfied AS
SELECT DISTINCT ts.gid,  
	   ts.area_sqm, 
	   ts.area_acre,
	   sc.average AS average_slope,
	   ts.geom
FROM temp_summary As ts
RIGHT JOIN (SELECT * 
			FROM slope_calculated 
			WHERE average <= 6) As sc
ON ts.gid = sc.gid;


-- 6. Geocoding

--- 6.1 Address Geocoding by JOIN
CREATE TEMPORARY TABLE geocoded AS
    SELECT DISTINCT ss.gid AS gid,
           ss.area_sqm AS AREA_SQM,
           ss.area_acre AS AREA_ACRE,
           ad.streetnum || ' ' || ad.streetname || ' ' || streettype AS Full_Address,
           ss.geom AS vacant_land_geom,
           ss.geom as address_points_geom
    FROM slope_satisfied ss
    LEFT JOIN address.addresses ad
    ON ST_Within(ad.geom, ss.geom)
    WHERE ad.municipali = 'Mississauga' AND ad.streettype IS NOT NULL;

-- 6.2 Aggregate Addresses as a List
CREATE TEMPORARY TABLE geocoded_aggregate AS
  SELECT
    gid,
    array_to_string(array_agg(Full_Address), ', ') AS Full_Address_List
  FROM geocoded
  GROUP BY gid;

-- 6.3 Creating Table as a Final Result
CREATE TABLE suitable_sites AS
  SELECT DISTINCT gc.gid AS gid,
    gc.AREA_SQM AS AREA_SQM,
    gc.AREA_ACRE AS AREA_ACRE,
    ga.Full_Address_List AS Full_Address_List,
    gc.vacant_land_geom AS vacant_land_geom
  FROM geocoded AS gc
  INNER JOIN geocoded_aggregate AS ga
  ON gc.gid = ga.gid
  ORDER BY gc.AREA_ACRE DESC;

-- 7. Retreive Table Results
SELECT gid AS GID,
       AREA_SQM AS "Area: Square Metres", 
       AREA_ACRE AS "Area: Acres",
       Full_Address_List AS "Full Address List",
       vacant_land_geom AS "Vacant Land Geometry"
FROM suitable_sites
ORDER BY AREA_ACRE DESC;