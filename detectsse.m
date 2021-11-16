function outsse = detectsse(s, np, propthresh, minsta, scoresign)
%detectSSE  Finds start dates and durations of SSEs
%   detectSSE(s, np, outfile, slopemult) uses a moving window slope
%   calculation to determine start dates and durations of slow slip events 
%   (SSEs) within position time series, then catalogs the events based on 
%   spatiotemporal proximity, and finally generates a displacement field 
%   for each SSE. 
%
%   The position time series information should be contained in structure
%   S, with fields as generated by pboposarrays.m. The key fields are 
%   nStations-by-nDays arrays sdate, sde, sse, sdn, and ssn, which are
%   datenum dates, east positions, east uncertainties, north positions, 
%   and north uncertainties, respectively. Days on which a station did 
%   not record should be denoted as zero values in each of these fields. 
%   
%   np defines size of evaluation window used to calculate each day's 
%   average slope. For each day i, slopes are calculated using a moving
%   window that begins on day (i - np) and ends on day (i + np).
%
%   outfile is the desired name of the saved .mat file containing key 
%   variables. 
%
%   slopemult defines the threshold for detecting SSEs on a particular 
%   day. It serves as a multiplier of the long-term slope, calculated
%   across each station's full observation duration, that must be 
%   exceeded by the daily averaged slopes from the moving window in 
%   order for that day to be denoted as participating in an SSE. 
%   slopemult is automatically converted to a negative number, as we
%   assume that an SSE produces motion opposite the long-term, 
%   nominally interseismic motion. 
%
%   Code by Elias Molitors Bergman and Jack Loveless
%

warning off 'MATLAB:nearlySingularMatrix'

% Get first and last days of observations for all stations
datesleft = shiftcols(s.sdate);
firstday = datesleft(:, 1);
datesright = shiftcols(s.sdate, -1);
lastday = datesright(:, end);

% Full vector of dates
[ns, nd] = size(s.sdate); % number of stations and dates
nzdates = s.sdate > 0; % Logical array identifying days on which observations exist
nzdates(s.sde == 0) = false; % Update for case where the date exists but position doesn't
fulldate = max(s.sdate); % All real date numbers
sse = false(ns, nd); % sse is a logical identifying days on which an SSE is nominally detected
duration = double(sse);
startdate = duration;
first = sse;
last = sse;

% Assumed thresholds
mindur = 10; % 10-day minimum duration
neighdist = 55; % Neighbor threshold distance in km

% Find distances between stations in order to define neighbors later
[lat1, lat2] = meshgrid(s.srefn);
[lon1, lon2] = meshgrid(s.srefe);
dists = distance(lat1, lon1, lat2, lon2, almanac('earth', 'ellipsoid', 'kilometers'));
didx = ns*(0:ns-1) + (1:ns); % Diagonal indices
dists(didx) = 1e6; % Set self distances to large numbers so that they're never found as the closest

% Calculate daily slopes, if they haven't already been calculated for this time window
if ~isfield(s, sprintf('dslopee%g', np))
   [score, pos, unc] = dailyslopes(s, np, 1);
   [score2, pos2, unc2] = dailyslopes(s, np, 2); 
   s = setfield(s, sprintf('dslopee%g', np), score);
   s = setfield(s, sprintf('dslopen%g', np), score2);
   s.pos = pos;
   s.pos2 = pos2;
   s.unc = unc;
   s.unc2 = unc2; 
else
   score = getfield(s, sprintf('dslopee%g', np));
   score2 = getfield(s, sprintf('dslopen%g', np));
   pos = s.pos;
   pos2 = s.pos2;
   unc = s.unc;
   unc2 = s.unc2;
end

scorethresh = zeros(ns, 1);
nsse = scorethresh;
if ~exist('scoresign', 'var')
   scoresign = 1;
end
score = scoresign*score;

% Determine which daily slopes are more negative than a prescribed threshold
for i = 1:ns % For each station, 
   [scoren, scorex] = hist(score(i, score(i, :) < 0), 100); % Histogram of negative daily slopes, 100 bins
   scoren = cumsum(fliplr(scoren))./sum(scoren); % Normalize histogram
   scorex = fliplr(scorex);
%   if sum(isnan(scoren)) < 100
   scorethresh(i) = scorex(find(scoren > propthresh, 1)); % Define the slope value of the nth percentile of negative slopes
   %
   % "sse" is logical array that is true for days on which an SSE is detected
   %
   sse(i, :) = score(i, :) < scorethresh(i); % Extract daily slopes that exceed the proportional threshold
   difference = diff([false, sse(i, :), false]); % Take the difference of sse to define starts and ends
   first(i, :) = [difference(1:end-1) == 1]; % Event start dates are those going from a 0 to a 1; during the event, diff is 0.
   last(i, :) = [difference(2:end) == -1]; % Event end dates are those going from a 1 to a 0
   firstdate = fulldate(first(i, :))'; % Get numerical date; add 1 because of shifted indexing of the diff operation
   lastdate = fulldate(last(i, :))'; % No need to shift indexing for last date

   ssedays = lastdate - firstdate + 1; % Add 1 because Duration should be all the days of detection
   good = ssedays >= mindur; % SSE must be longer than mindur days

   % Adjust first and last, discarding values corresponding to short SSE detections
   firstidx = find(first(i, :)); firstidx = firstidx(~good);
   lastidx = find(last(i, :)); lastidx = lastidx(~good);
   first(i, firstidx) = false;
   last(i, lastidx) = false;
   % Create duration matrix, assigning duration to columns of SSE starts      
   duration(i, first(i, :)) = ssedays(good);
   % Create start date matrix, assigning start date to columns of SSE starts
   startdate(i, first(i, :)) = fulldate(first(i, :));
   nsse(i) = length(find(startdate(i, :))); % number of good SSEs detected at this station
%   end
end % End SSE detection loop

% Columns of startdate:
% 1: datestr of start dates
% 2: datenum of start dates
% 3: Notes about station w.r.t. neighbors
% 4: Day index of start dates
% 5: Logical indicating whether events belong to combined catalog
% 6: Start dates of events not in combined catalog

% Neighbor filtering
neighbor = dists <= neighdist & dists > 0; % neighbors are stations within specified distance of one another
noneighbs = false(ns, 1); % Allocate space for logical array indicating whether station has no neighbors
foneighbs = false(ns, 1); % Allocate space for logical array indicating whether station is the first of its neighbors to record
for i = 1:ns
   n = find(neighbor(i, :)); % list all neighbors of station i
   %-------------------------
   % Station has no neighbors
   %-------------------------
   if isempty(n) % if a station has no neighbors, no startdates will be thrown away, but its neighborlessness will be recorded
      noneighbs(i) = true;
   else
      %-------------------------
      % Station has neighbors
      %-------------------------
      if sum(firstday(i) > firstday(n)) == 0 % station has been recording since before all neighbors
         %-------------------------
         % Station was the first of its neighbors
         %-------------------------
         foneighbs(i) = true; 
      end
      preneigh = startdate(i, first(i, :)) < min(firstday(n)); % Indices of this station's SSEs that occurred before neighbors were installed
      surrounding = zeros(nsse(i), length(n)); % Allocate space for temporally close SSEs at neighbors
      for k = 1:length(n)
         surrounding(:, k) = ismembertol(startdate(i, first(i, :)), startdate(n(k), first(n(k), :)), np, 'DataScale', 1); % Same SSEs at neighbors defined as those within np days
      end
      ikeep = sum(surrounding, 2) >= length(n)/10; % Keep SSEs felt by more than 1/10 of neighbors
      ikeep(preneigh) = true; % only subject station to filtering after it has at least 1 neighbor online
      firstidx = find(first(i, :)); firstidx = firstidx(~ikeep);
      lastidx = find(last(i, :)); lastidx = lastidx(~ikeep);
      duration(i, firstidx) = 0;
      first(i, firstidx) = false;
      last(i, lastidx) = false;
   end
end

issse = cumsum(first - last, 2); issse(last) = true;
issse = logical(issse);
ssedur = issse.*duration;
 
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Constructing a catalog based on number of stations %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%function [spikeday, spikebeg, spikeend, spikesta] = ssecatalog(s, issse, np)

% Define default minimum stations, if not specified
if ~exist('minsta', 'var')
   minsta = 10;
end
many = sum(issse) >= 2; % Find dates on which 2 or more stations felt SSE
difference = diff([false, many, false]);
spikeend = find(difference(2:end) == -1); % Ends of station number spikes
spikebeg = find(difference(1:end-1) == 1); % Beginnings of station number spikes
spikedur = spikeend - spikebeg; % Duration of spike
spikeday = spikebeg + round(spikedur/2); % Day of spike
nspike   = numel(spikeday);

% Collapse closely spaced spikes
dspike = [diff(spikeday), 1e6]; % Separation of spikes, augmented with a big number at the end for subsequent indexing
closesep = dspike <= 2*np; % Closely separated are those events less than np days apart
closesep = logical(closesep); % Combine events that need collapsing
collend = find(diff(closesep) == -1) + 1; % Last events to be collapsed
collbeg = find(diff(closesep) == 1) + 1; % First events to be collapsed
if ~isempty(collend)
   if collend(1) < collbeg(1) % Special case when first event needs to be collapsed 
      collbeg = [1 collbeg];
   end
end

% Indices for keeping beginning and end of refined events
spikekeep1 = setdiff(1:nspike, collbeg);
spikekeep2 = setdiff(1:nspike, collend);
spikebeg = spikebeg(spikekeep2); % Get subset of spikebeg
spikeend = spikeend(spikekeep1); % Get subset of spikeend
spikedur = spikeend - spikebeg; % Duration of spike
spikeday = spikebeg + round(spikedur/2); % Day of spike defined as middle of duration
nspike   = numel(spikeday); % Update number of spikes

% Find detections that intersect the duration of spikes:
% Which stations felt each spike
spikesta = false(ns, nspike); % Allocate space
for i = 1:nspike
   % Catalog stations that overlap by at least one day; actual start/end will be used in displacement calculation 
   spikesta(:, i) = sum(issse(:, spikebeg(i):spikeend(i)), 2) > 0; 
end

% Extract events felt by >= minsta
keepevent = sum(spikesta) >= minsta;
spikebeg = spikebeg(keepevent); % Get subset of spikebeg
spikeend = spikeend(keepevent); % Get subset of spikeend

% Combine events with overlapping durations
overlaps = [false, spikebeg(2:end) < spikeend(1:end-1)]; % Events that overlap
spikebeg = spikebeg(~overlaps);
overlaps = [overlaps(2:end), false];
spikeend = spikeend(~overlaps); % Get spikeends, shifting overlaps left
spikedur = spikeend - spikebeg; % Duration of spike
spikeday = spikebeg + round(spikedur/2); % Day of spike defined as middle of duration
nspike   = numel(spikeday); % Update number of spikes

% Find detections that intersect the duration of spikes:
% Which stations felt each spike
spikesta = false(ns, nspike); % Allocate space
for i = 1:nspike
   % Catalog stations that overlap by at least one day; actual start/end will be used in displacement calculation 
   spikesta(:, i) = sum(issse(:, spikebeg(i):spikeend(i)), 2) > 0; 
end

% Visualize
figure
[~, latsort] = sort(s.srefn, 'descend');
patch(fulldate([spikebeg; spikeend; spikeend; spikebeg]), repmat([min(s.srefn)-0.1; min(s.srefn)-0.1; max(s.srefn)+0.1; max(s.srefn)+0.1], size(spikeday)), [1 0.8 0.8], 'edgecolor', 'none');
hold on
plotdate = repmat(fulldate, ns, 1);
plotlat = s.srefn(latsort); plotlat = repmat(plotlat, 1, nd);
plot(plotdate(issse(latsort, :)), plotlat(issse(latsort, :)), '.k', 'markersize', 1)
%pcolor(fulldate, s.srefn(latsort), double(issse(latsort, :))); shading flat;
colormap(flipud(gray))
%patch(fulldate([spikebeg; spikeend; spikeend; spikebeg]), repmat([min(s.srefn); min(s.srefn); max(s.srefn); max(s.srefn)], size(spikeday)), 'r', 'facealpha', 0.15, 'edgecolor', 'none');
line(fulldate([spikeday; spikeday]), repmat([min(s.srefn)-0.1; max(s.srefn)+0.1], size(spikeday)), 'color', 'r')
datetick
xlabel('Date'); ylabel('Latitude')
axis tight
prepfigprint

% Initialize final catalog variable
counter = zeros(ns, length(spikeday));
listsse = counter;
durationsse = counter;
eastVel = counter;
northVel = counter;
eastSig = counter;
northSig = counter;

feltsse = logical(counter);
neighborfelt = feltsse;
finalsse = zeros(ns, nd);

% Assign startdates to each cataloged event 
for i = 1:ns
    for j = 1:length(spikebeg)
       stafelt = startdate(i, first(i, :)) >= fulldate(spikebeg(j)) & startdate(i, first(i, :)) < fulldate(spikeend(j));
       feltsse(i, j) = sum(stafelt);
       if feltsse(i, j)
          counter(i, j) = find(stafelt, 1);
       end
    end    
end

for i = 1:ns % For each station, 
    n = find(neighbor(i, :)); % Identify neighbors
    for j = 1:size(feltsse, 2) % For each event felt in catalog,
        if fulldate(spikeday(j)) < firstday(i)
            feltsse(i, j) = false; % events before station came online
        end
        if fulldate(spikeday(j)) > lastday(i)
            feltsse(i, j) = false; %...or after station offline
        end
        
        % Reverse neighbor filter
        % If the station did not feel this event,
        
        if ~feltsse(i, j) 
            if sum(feltsse(n, j)) > (length(n)/3) % But more than 1/3 of its neighbors did,
                % station is artificially considered to have felt it
                neighborfelt(i, j) = true; % a designation for special treatment
            end
        end
    end   
    thisfirst = startdate(i, first(i, :));
    thisdur = ssedur(i, first(i, :));
    for j = 1:size(feltsse, 2)
        if feltsse(i, j)
            listsse(i, j) = thisfirst(counter(i, j)); % Use station's own startdate
            durationsse(i, j) = thisdur(counter(i, j)); % and Duration
            ssedates = listsse(i, j):listsse(i, j) + durationsse(i, j); % Define SSE dates
            [~, loc] = ismember(ssedates, s.sdate(i, :)); % Find indices of SSE dates within station's date vector
            keep = loc ~= 0;
            loc = loc(keep);
            if ~isempty(loc)
				finalsse(i, loc) = 1;
				slopemat = [(ssedates(keep))', ones(size(loc))']; % Design matrix for fitting a linear function to SSE positions
				% Convert uncertainties on positions to weights
				sigma = diag(1./unc(i, loc).^2);
				% Calculate model covariance using backslash
				cov = (slopemat'*sigma*slopemat)\eye(size(slopemat, 2));
				slope = cov*slopemat'*sigma*pos(i, loc)';
				% Calculate model parameters
				eastVel(i, j) = diff(slopemat([1; end], :)*slope); % Displacement is difference between function evaluated on first and last days
				eastSig(i, j) = sqrt(cov(1));
 
				sigma = diag(1./unc2(i, loc).^2);
				% Calculate model covariance using backslash
				cov = (slopemat'*sigma*slopemat)\eye(size(slopemat, 2));
				% Calculate model parameters
				slope = cov*slopemat'*sigma*pos2(i, loc)';
				northVel(i, j) = diff(slopemat([1; end], :)*slope);
				northSig(i, j) = sqrt(cov(1));
            end
        end
    end
end

% Treat reverse neighbor events
revneighb = 0;
if revneighb == 1

for i = 1:ns
    for j = 1:size(feltsse, 2)
        if neighborfelt(i, j)
            felt = find(feltsse(:, j)); % Identify other stations that felt this event
            % Another check for empty, because feltsse could be set to false for a given station 
            % AFTER (in a loop sense) that station is used to set neighborfelt to true
            if ~isempty(felt) 
				nearest = find(dists(:, i) == min(dists(felt, i))); % Find the closest station
				listsse(i, j) = listsse(nearest, j); % Assign the start date of the closest station to this station
				durationsse(i, j) = durationsse(nearest, j); % Same with duration
				ssedates = listsse(i, j):listsse(i, j) + durationsse(i, j); % Define SSE dates
				[keep, loc] = ismember(ssedates, s.sdate(i,:));
				if sum(keep) < durationsse(i, j)/2 % If there are fewer daily observations than half the event duration,
					feltsse(i, j) = false; % Undo the reverse neighbor filter
					neighborfelt(i, j) = false;
					continue
				end
				% If there are sufficient observations, estimate event displacement components 
				loc = loc(keep);
				finalsse(i, loc) = 2;
				slopemat = [(ssedates(keep))', ones(size(loc))'];
				% Convert uncertainties on positions to weights
				sigma = diag(1./unc(i, loc).^2);
				% Calculate model covariance using backslash
				cov = (slopemat'*sigma*slopemat)\eye(size(slopemat, 2));
				% Calculate model parameters
				slope = cov*slopemat'*sigma*pos(i, loc)';
				eastVel(i, j) = diff(slopemat([1; end],:)*slope);
				eastSig(i, j) = sqrt(cov(1));
			
				sigma = diag(1./unc2(i,loc).^2);
				% Calculate model covariance using backslash
				cov = (slopemat'*sigma*slopemat)\eye(size(slopemat, 2));
				% Calculate model parameters
				slope = cov*slopemat'*sigma*pos2(i, loc)';
				northVel(i, j) = diff(slopemat([1; end],:)*slope);
				northSig(i, j) = sqrt(cov(1));
            end
        end
    end
end

end % End of reverse neighbor if statement

% Trimming of some duplicates
%[c, ia] = unique(durationsse', 'rows');
%durationsse  = durationsse(:, sort(ia));
%eastSig      = eastSig     (:, sort(ia));
%eastVel      = eastVel     (:, sort(ia));
%feltsse      = feltsse     (:, sort(ia));
%listsse      = listsse     (:, sort(ia));
%neighborfelt = neighborfelt(:, sort(ia));
%northSig     = northSig    (:, sort(ia));
%northVel     = northVel    (:, sort(ia));

% Prepare output structure
outsse.daterange = [fulldate(spikebeg(:)); fulldate(spikeend(:))]';
outsse.durationsse = durationsse;
outsse.sselogical = sse;
outsse.eastVel = eastVel;
outsse.eastSig = eastSig;
outsse.northVel = northVel;
outsse.northSig = northSig;
outsse.listsse = listsse;
outsse.score = score;
outsse.scorethresh = scorethresh;
outsse.score2 = score2;
outsse.name = s.sname;
outsse.date = s.sdate;
outsse.lon = s.srefe;
outsse.lat = s.srefn;
outsse.sde = s.sde;
outsse.sdn = s.sdn;
outsse.firstday = firstday;
outsse.lastday = lastday;