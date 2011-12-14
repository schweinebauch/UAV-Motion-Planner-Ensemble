close all; clear all; clc;
% What this file does:
% Sets up a 2D simulation of a robot navigating an obstacle filled area
% Robot is considered a point with a 360 range of view
% Obstacles have actual locations (ground truths) and 
%    estimated locations based on # of times seen (using a noise filter variation of normal distribution)
%
% Two planners are implemented at different scales
%  Globally - A Voronoi diagram is built based on 'all objects ever seen' and their estimated locations
%    This planner A*/DFS nodes to the global goal, choosing a local goal avoiding some global minima
%  Locally - A Potential Field is built based on currently visible obstacle uncertainties & distances to robot
%    This planner is used to guide a robot to the local goal, on a smaller step size than global plan

% Right now the noise function only takes into account number of times point has previously been viewed
% It would be interesting to make noise also a function of distance, which can be implemented easily
% Any noise filter you'd like to implement should take an output of the format:
% 2xN for N visible points, then it can just directly replace the current noiseFilter

%% RANDOM SEED
% Reset random generator to initial state for repeatability of tests
%RandStream.setDefaultStream(RandStream('mt19937ar', 'Seed', ceil(rand*1000000)));
SEED = 293;
RandStream.setDefaultStream(RandStream('mt19937ar', 'Seed', SEED));
%% USER DEFINED Values

% Simulator
TURNS = 1000; % Number of turns to simulate
N = 1000; % Number of points in playing field
BBOX = [0 0 100 100]; % playing field bounding box [x1 y1 x2 y2]
global_goal = [90 90]; % Global goal position (must be in BBOX)

% Robot
robot_pos = [10 10]; % x,y position
robot_rov = 15; % Range of view
DMAX = 0.5; % max robot movement in one turn
MINDIST = 0.1; % Minimum distance from goal score
TRAIL_STEP_SIZE = 0.5; % minimum distance of each trail step % Robot still traveld DMAX steps (just only saves trail every trail-step-size)
TREE_SIZE = 1;    %The minimum distance we can pass from a tree. 
                    %Affects which Voronoi edges are pruned in global
                    %and cost of getting close to a tree in local

LOCAL_GOAL_DIST_MAX = robot_rov/2; % Max Distance to choose local goal from a* plan
LOCAL_GOAL_DIST_MIN = 0.1; % Min distance to choose local goal from
LOCAL_GOAL_DIST_DEGRADE = 0.5; % Rate of choosing closer goals when stuck in minima
LOCAL_GOAL_DIST = LOCAL_GOAL_DIST_MAX; % Current distance for choosing local goal (decays/changes)
LOCAL_GOAL_DIST_RECOVER = 6; %Number of turns for LOCAL_GOAL_DIST to recover to robot_rov after being stuck
STUCK_TIME = 30; %Number of points in a row that must be near each other to be considered stuck




LOCAL_DIST_FORCE_MIN = 1;
LOCAL_DIST_FORCE_MAX = 1;
LOCAL_DIST_FORCE = LOCAL_DIST_FORCE_MIN; % Amount of force obstacles distance has on potential field
LOCAL_DIST_FORCE_STEP = 1;
LOCAL_DIST_FORCE_DEGRADE_RATE = 0.9; % Rate per turn of reduction of LOCAL_DIST_FORCE
LOCAL_STUCK_MINIMA_THRESHOLD = 0.1; % Threshold at which local_goal_path std considered stuck


% FIGURES (LOCAL - contour, and GLOBAL - 2d trail)
SHOW_ACTUAL_OBSTACLES = false; % whether to plot grount truth position of obstacles or not
DO_LOCAL = false; % plot local planner contour figure
SHOW_LOCAL_CONTOUR = true; % Plot only local area of contour versus entire BBOX
FIG_SIZE = [590 660]*2; % Both Figure sizes
FIG_POS1 = [50 10]; % Local figure position
FIG_POS2 = [60 10]; % Global figure position
LEGEND_POS = 'NorthWest';

% AVI FILES
COMPRESSION = 'FFDS'; % Use 'None' for no compression (only simple way to run on Win7/Linux, need to install ffdshow for option 'FFDS' )
Global_filename = sprintf('simAll_2D_7_ROV%i_N%i_C.avi',robot_rov,N); 
Local_filename = sprintf('simAll_contour_7_ROV%i_N%i_C.avi',robot_rov,N);
DO_AVI = false; % write any avi files at all (Global & Local)
DO_LOCAL_AVI = true; % write contour avi file
FRAME_REPEATS = 2; % Number of times to repeat frame in avi (slower framerate below 5 which fails on avifile('fps',<5))

% Noise Function
[noiseFilt sigmaV] = noiseFilter(); %noiseFilt = makeNoiseFilter(0,0.4,30,10,1.4);
%sigmaV = @(x) 0; % Zero sigma function
LOW_NOISE_CONFIDENCE_THRESHOLD = 0.0; % Threshold of average noise, DO NOT USE, Skipping voronoi breaks the LOCAL_DIST_FORCE stuff

%save(sprintf('setupN%i',N)); % Saves user-def variables for the run

%% SETUP
getRandPoints = @(N,x1,y1,x2,y2) [ones(1,N)*x1; ones(1,N)*y1] + rand(2,N).*[ones(1,N)*(x2-x1); ones(1,N)*(y2-y1)];
getDist = @(a,b) sqrt((b(:,2)-a(2)).^2 + (b(:,1)-a(1)).^2); % a must be 2 elemnts, b can be vector of 2 cols x N rows
obstacles = getRandPoints(N,BBOX(1),BBOX(2),BBOX(3),BBOX(4)); % Initial random distribution of points
%load obstacle2;
%load obstacles;
% obstacles = [10 15; 
%              10 5;
%              10 10;
%              10 2;
%              10 18;]';

views = zeros(1,N); % Number of times point has been seen before, this affects the noiseFilter as value passed into viewsCount (more = less noise)
obstacleEstimate = zeros(2,N); % Last (estimated) Known position of obstacles
obstacleLastKnown = zeros(2,N); % Last known all obstacles
distances = zeros(1, N); % Init current distances between robot and obstacles
robot_trail = robot_pos;%zeros(TURNS,2); % Initialize robot position history

% Axis & Views
AX = [BBOX(1),BBOX(3),BBOX(2),BBOX(4)];
azel = [-123.5 58]; % for view in saving files
closestEncounter = inf; % Closest distance of robot to any obstacle
closestPos = [0,0]; % Position of closest encounter

% Run loop variables
foundGoal = 0;
checkRepeat0It = 0;


% Setup AVI files
if DO_AVI
    aviobj = avifile(Global_filename,'compression',COMPRESSION,'fps',5); % Global AVI
    if DO_LOCAL_AVI
        aviobj2 = avifile(Local_filename,'compression',COMPRESSION,'fps',5); % Local AVI
    end
end

%% Set up Figures
if DO_LOCAL
    fh1 = figure(1); % 3D Contour Figure (Left)
    pos = get(gcf, 'position');
    pos(1:2) = FIG_POS1;
    pos(3:4) = FIG_SIZE;
    set(gcf, 'position', pos);
end

fh2 = figure(2); % Ground Truth Figure with Voronoi (Right)
axis(AX);
pos = get(fh2, 'position');
pos(1:2) = FIG_POS2;
pos(3:4) = FIG_SIZE;
set(fh2, 'position', pos);

%% RUN LOOP
fprintf(2,'  Magenta Diamond - UAV position\n');
fprintf(2,'        Blue Star - Local Goal\n');
fprintf(2,'         Red Star - Global Goal\n');
fprintf(2,'        Black dot - Ground truth positions of obstacles (unknown to UAV)\n');
fprintf(2,'        Green dot - Last known observed position of obstacle (connected to ground truth position with green dotted line)\n');
fprintf(2,'Blue dotted-lines - Voronoi diagram\n\n');

for i = 1:TURNS
    pause(0.0001); % For update graphics, any pause >0 works
   fprintf('TURN %i : ',i);
   
   % Calculate obstacle visibility etc. based on position
   distances = getDist(robot_pos,obstacles');
   views(distances<robot_rov) = views(distances<robot_rov) + 1;
   viewCurrent = zeros(1,N); % localPlanner view sees only currently visible obstacles
   viewCurrent(distances<robot_rov) = 1; % only 1's and 0's for obstacles currently visible or not
   
   % The noise based on view count for all obstacles
   noise = noiseFilt(  views );
   
   % update noise only for those currently seeing 
   obstacleLastKnown(:,viewCurrent~=0) = obstacles(:,viewCurrent~=0) + noise(:,viewCurrent~=0);
   
   obstacleEstimate = obstacleLastKnown(:,views~=0); % only obstacles that have ever been visible
   obstacleCurrent = obstacleLastKnown(:,viewCurrent~=0); % Only currently visible obstacles (no 0's)
   
   obstacleObjects = cell(1,sum(viewCurrent));
   for k = 1:sum(viewCurrent)
       obstacleObjects{k}.x = obstacleCurrent(1,k);
       obstacleObjects{k}.y = obstacleCurrent(2,k);
       v = views(logical(viewCurrent));
       obstacleObjects{k}.sig = sigmaV(v(k));
   end
   
   %% RUN PLANNERS---------------------------------------------------------
   
   %%% VORONOI PLANNER - Determine Local Goal given known obstacles, and global goal
   
   % Average Noise 'distance' of visible obstacles
   avgNoiseVisibleObstacles = sum(sqrt(sum( noise(:,viewCurrent~=0).^2  ,1))) / sum(viewCurrent);
   
   if (avgNoiseVisibleObstacles > LOW_NOISE_CONFIDENCE_THRESHOLD)   
    [local_goal,noPathExists,VX,VY,VXnew,VYnew,PX,PY] = voronoi_planner(obstacleEstimate', robot_pos, global_goal, TREE_SIZE*1.2, LOCAL_GOAL_DIST);
   else
       disp('Low noise - continuing previous Voronoi path');
   end
%    local_goal = robot_pos+20*(global_goal-robot_pos)/getDist(robot_pos,global_goal); % 10% towards global_goal

   if noPathExists
       disp('No Path exists, waiting for less uncertainty');
       continue;
   end
   % If Voronoi is being bad, ignore it
   if (getDist(robot_pos,local_goal) > getDist(robot_pos,global_goal))
       local_goal = global_goal; % global goal is closer than local goal
%    elseif (getDist(robot_pos,local_goal) < DMAX)  
%        % SPECIAL CASE - if local goal < DMAX just go there directly and
%        %   skip everything else
%        % If Voroni local goal is closer than DMAX, just go there and again.
%        fprintf(' JUMP ');
%        robot_pos = local_goal;
%        if getDist(robot_pos,robot_trail(end,:)) >= TRAIL_STEP_SIZE
%            robot_trail(end+1,:) = robot_pos; % Keep history of robot positions;
%        end
%        continue;
   end
   
   
   
   %%% LOCAL PLANNER - must come before Update Robot (needs local_goal and robot position)
   
   
   
   % Only given those obstacles it currently sees
   local_goal_path = localplan(robot_pos, local_goal, obstacleObjects, LOCAL_DIST_FORCE);
   %local_goal_path = localplan(robot_pos, global_goal, obstacleObjects);
   
   % If current path is stuck in a local minima, increase effect of
   % obstacle distances
   
   % Update local force effect
   if (LOCAL_DIST_FORCE*LOCAL_DIST_FORCE_DEGRADE_RATE > LOCAL_DIST_FORCE_MIN)
       LOCAL_DIST_FORCE = LOCAL_DIST_FORCE*LOCAL_DIST_FORCE_DEGRADE_RATE;
   else
       LOCAL_DIST_FORCE = LOCAL_DIST_FORCE_MIN;
   end
   
   % Check if local path is stuck in minima, if so change force & local
   % goal to closer
   if (sum(std(local_goal_path).^2) < LOCAL_STUCK_MINIMA_THRESHOLD)
       if (LOCAL_DIST_FORCE + LOCAL_DIST_FORCE_STEP < LOCAL_DIST_FORCE_MAX)
           LOCAL_DIST_FORCE = LOCAL_DIST_FORCE + LOCAL_DIST_FORCE_STEP;
           fprintf('Force up : %g\n' , LOCAL_DIST_FORCE);
       end
       if LOCAL_GOAL_DIST*LOCAL_GOAL_DIST_DEGRADE > LOCAL_GOAL_DIST_MIN
           LOCAL_GOAL_DIST = LOCAL_GOAL_DIST*LOCAL_GOAL_DIST_DEGRADE;
       else
           LOCAL_GOAL_DIST = LOCAL_GOAL_DIST_MIN;
       end
   end
   % Check stuck criteria
   if size(local_goal_path,1) == 1
       checkRepeat0It = checkRepeat0It + 1;
       if (checkRepeat0It > 10)
           % Stuck in equilibrium, apply nudge towards local goal
           local_goal_path = [local_goal_path;local_goal];
           checkRepeat0It = 0;
       end
   end
   
   
   %% Find closest encounter to ground truth obstacles
   d = 0;
   for k = 1:N
       d = getDist(robot_pos,obstacles(:,k)');
       if d < closestEncounter
           closestEncounter = d;
           closestPos = robot_pos;
       end
   end
   
   
   %% GRAPHICS -----------------------------------------
   
   %% START GLOBAL PLOT - What we observe ( RIGHT FIGURE)
   figure(fh2);
   % Plot VORONOI LINES
   hold off;
   plot(VX,VY,':','Color',[0.8 0.8 0.8]); 
   hold on;
   plot(PX,PY,'y','LineWidth',3);  
   plot(VXnew,VYnew,'b:');   
   set(fh2(1:end-1),'xliminclude','off','yliminclude','off'); % keep infinite lines clipped
   axis('equal'); axis(AX);
   
   % Observed Obstacles
   observedObsH = scatter(obstacleEstimate(1,:),obstacleEstimate(2,:),'g','filled');
   
   hold on;
   
   
   % Plot connector line between ground truth to observed
   gt = obstacles(:,views~=0);
   es = obstacleEstimate;
   for k = 1:size(es,2)
       % For each connection (estimate)
       plot([gt(1,k) es(1,k)],[gt(2,k) es(2,k)],'g:');
   end
   
   % Robot
   plot([robot_trail(robot_trail(:,1)~=0,1); robot_pos(1)],[robot_trail(robot_trail(:,2)~=0,2); robot_pos(2)],'b.-'); % Robot Trail
   robotPosH = scatter(robot_pos(1), robot_pos(2),80, 'md','filled'); % Robot position
   drawCircle(robot_pos(1),robot_pos(2), robot_rov, 'b-'); % Robot Field of View (vision range)
   
   % Local & Global Goals
   localGoalH = scatter(local_goal(1),local_goal(2),100,'cp','filled'); % Plot local goal
   globalGoalH = scatter(global_goal(1),global_goal(2),150,'rp','filled'); % Plot global goal 
   
   if SHOW_ACTUAL_OBSTACLES
       % Ground truth - black
       groundTruthH = scatter( obstacles(1,:),obstacles(2,:),'k.');
       legend([robotPosH localGoalH globalGoalH observedObsH groundTruthH],'UAV position','Local Goal','Global Goal', 'Observed/Estimated Obstacle Positions', 'Ground Truth Obstacle Positions','Location',LEGEND_POS);
   else
       legend([robotPosH localGoalH globalGoalH observedObsH],'UAV position','Local Goal','Global Goal', 'Observed/Estimated Obstacle Positions','Location',LEGEND_POS);
   end
   
   title(sprintf('%i Obstacles, Turn %i : Distance to Global Goal = %g\nClosest Encounter = %g @ P(%g,%g)',N,i,getDist(robot_pos,global_goal),closestEncounter,closestPos(1),closestPos(2)));
   hold off;
   
   % write AVI of GLOBAL
   if DO_AVI
       f2 = getframe(fh2);
       for k = 1:FRAME_REPEATS
           aviobj = addframe(aviobj,f2); % Save to avi
       end
   end   
   
   
   %% START LOCAL PLOT - 3D Contour path for LOCAL Planner (ie. to Local goal)
   if DO_LOCAL && size(local_goal_path,1) > 1 % also can't plot if there is no path
       if SHOW_LOCAL_CONTOUR
           plotlocal(obstacleObjects, local_goal, global_goal, local_goal_path, LOCAL_DIST_FORCE, '' ,fh1); % new figure 3d contour
       else
           plotlocal(obstacleObjects, local_goal, global_goal, local_goal_path, LOCAL_DIST_FORCE, AX ,fh1); % new figure 3d contour
       end
       axis('equal'); axis(AX);
       view(azel);
       view(2);

       % SAVE FIG AND AVI
       %saveas(gcf,sprintf('localMinima%i',i),'fig');
       title(sprintf('Turn %i : Distance to Local Goal = %g',i,getDist(robot_pos,global_goal)));
       if DO_AVI && DO_LOCAL_AVI
           f1 = getframe(fh1);
           for k=1:FRAME_REPEATS
               aviobj2 = addframe(aviobj2,f1); % Save to avi
           end
       end
   end 
   
   %% Update Robot - must be before 
   d = 0; k = 0;
   % Update Robot position along local path trail for distance DMAX
   while d < DMAX
       if getDist(robot_pos,robot_trail(end,:)) >= TRAIL_STEP_SIZE
           robot_trail(end+1,:) = robot_pos; % Keep history of robot positions;
       end
       if getDist(robot_pos,global_goal) < MINDIST || getDist(robot_pos,global_goal) < (DMAX-d) % Found the goal!
           if foundGoal == 1
               disp('Almost there...');
           end
           foundGoal = foundGoal + 1;
           robot_pos = global_goal;
           robot_trail(end+1,:) = robot_pos;
           break
       end
       
       if (2+k > size(local_goal_path,1)) % Next path point is further than path exists
           % Can't go any further so just go to the last point
           next_pos = local_goal_path(end,:); % choose last position
           robot_pos = next_pos; % Update position
           break;
       end
       % Next position is point on local goal path
       next_pos = local_goal_path(2+k,:); % choose next position from local plan
       d = d + getDist(robot_pos,next_pos); % distance traveled increased by motion
       k = k + 1; % next point in path
       % Update position 
       if (d > DMAX)
           % robot wants to move too far, so interpolate along distance
           robot_pos = robot_pos + (DMAX-d+getDist(robot_pos,next_pos))*(next_pos-robot_pos)/getDist(robot_pos,next_pos);
       else
          robot_pos = next_pos; 
       end
   end
   
   %% Check End State or Stuck State
   if (foundGoal == 2) % If we found goal, we're done!
       fprintf('You made it in %i steps.\n',i);
       break
   end
   if (length(robot_trail) > STUCK_TIME && sum(std(robot_trail(end-STUCK_TIME:end,:)).^2) < 0.3) % If last 10 points were roughly same spot, we're stuck and done.
       disp('Stuck in Loop.') 
   end
   
   % Recover goal distance to normal
   if (LOCAL_GOAL_DIST < LOCAL_GOAL_DIST_MAX)
       LOCAL_GOAL_DIST = LOCAL_GOAL_DIST + LOCAL_GOAL_DIST_MAX/LOCAL_GOAL_DIST_RECOVER;
       if (LOCAL_GOAL_DIST > LOCAL_GOAL_DIST_MAX)
           LOCAL_GOAL_DIST = LOCAL_GOAL_DIST_MAX;
       end
   end
   %pause
end

%% Close AVI files
if DO_AVI
    aviobj = close(aviobj);
    fprintf('\nSaved global voronoi path and robot movement overlay movie to ''%s'' : ',Global_filename);
    fprintf('Global (Voronoi) Path Plan with %i obstacles\n',N);
    if DO_LOCAL_AVI
        aviobj2 = close(aviobj2);
        fprintf('Saved local potential field path movie to ''%s'' : ',Local_filename);
        fprintf('Local (Potential Field) Path Plan with %i obstacles\n',N);
    end
end