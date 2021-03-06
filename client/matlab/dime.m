% dime.m - DiME client for Matlab
% Copyright (c) 2020 Nicholas West, Hantao Cui, CURENT, et. al.
%
% Permission to use, copy, modify, and/or distribute this software for any
% purpose with or without fee is hereby granted, provided that the above
% copyright notice and this permission notice appear in all copies.
%
% This software is provided "as is" and the author disclaims all
% warranties with regard to this software including all implied warranties
% of merchantability and fitness. In no event shall the author be liable
% for any special, direct, indirect, or consequential damages or any
% damages whatsoever resulting from loss of use, data or profits, whether
% in an action of contract, negligence or other tortious action, arising
% out of or in connection with the use or performance of this software.

classdef dime < handle
    % DiME client
    %
    % Allows a Matlab process to send/receive variables from its workspace to
    % other clients connected to a shared DiME server. Note that this class
    % includes several method aliases to be as API-compatible with the original
    % DiME client as possible; However, since DiME2 introduces concepts foreign
    % to the original DiME (e.g. groups), full API compatibility may not be
    % attainable.

    properties (Access=private)
        serialization % Serialization method currently in use
        send_ll       % Low-level send function
        recv_ll       % Low-level receive function
        close_ll      % Low-level close function
    end

    methods
        function obj = dime(proto, varargin)
            % Construct a dime instance
            %
            % Create a dime client via the specified protocol. The exact
            % arguments depend on the protocol:
            %
            % * If the protocol is 'ipc', then the function expects one
            %   additional argument: the pathname of the Unix domain socket
            %   to connect to.
            % * If the protocol is 'tcp', then the function expects two
            %   additional arguments: the hostname and port of the TCP socket
            %   to connect to, in that order.
            %
            % Parameters
            % ----------
            % proto : {'ipc', 'tcp'}
            %     Transport protocol to use.
            %
            % varargin
            %     Additional arguments, as described above.
            %
            % Returns
            % -------
            % dime
            %     The newly constructed dime instance.

            if (nargin == 0)
                proto = 'ipc';
                varargin = {'/tmp/dime.sock'};
            end

            switch (proto)
            case {'ipc', 'unix'}
                conn = sunconnect(varargin{:});

                obj.send_ll = @(msg) sunsend(conn, msg);
                obj.recv_ll = @(n) sunrecv(conn, n);
                obj.close_ll = @() sunclose(conn);

            case 'tcp'
                conn = tcpclient(varargin{:});

                obj.send_ll = @(msg) write(conn, msg);
                obj.recv_ll = @(n) read(conn, n);
                obj.close_ll = @() []; % TODO: does clear() close a TCP socket?

            otherwise
                match = regexp(proto, '^(?<proto>[a-z]+)://(?<hostname>([^:]|((?<=\\)(\\\\)*:))+)(?<port>:[0-9]+)?$', 'names');

                if ~isempty(match)
                    switch (match.proto)
                    case {'ipc', 'unix'}
                        conn = sunconnect(match.hostname);

                        obj.send_ll = @(msg) sunsend(conn, msg);
                        obj.recv_ll = @(n) sunrecv(conn, n);
                        obj.close_ll = @() sunclose(conn);

                    case 'tcp'
                        conn = tcpclient(match.hostname, str2num(match.port(2:length(match.port))));

                        obj.send_ll = @(msg) write(conn, msg);
                        obj.recv_ll = @(n) read(conn, n);
                        obj.close_ll = @() []; % TODO: does clear() close a TCP socket?
                    end
                end
            end

            jsondata = struct();

            jsondata.command = 'handshake';
            jsondata.serialization = 'matlab';
            jsondata.tls = false;

            sendmsg(obj, jsondata, uint8.empty);
            [jsondata, ~] = recvmsg(obj);

            if jsondata.status < 0
                error(jsondata.error);
            end

            obj.serialization = jsondata.serialization;
        end

        function delete(obj)
            % Destruct a dime instance
            %
            % Performs cleanup of a DiME client connection. This generally
            % means closing the socket on which the connection was opened.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.

            obj.close_ll();
        end

        function [] = join(obj, varargin)
            % Send a "join" command to the server
            %
            % Instructs the DiME server to add the client to one or more groups
            % by name.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % varargin : cell array of strings
            %    The group name(s).

            jsondata = struct();
            jsondata.command = 'join';
            jsondata.name = varargin;

            sendmsg(obj, jsondata, uint8.empty);

            [jsondata, ~] = recvmsg(obj);

            if jsondata.status < 0
                error(jsondata.error);
            end
        end

        function [] = leave(obj, varargin)
            % Send a "leave" command to the server
            %
            % Instructs the DiME server to remove the client from one or more
            % groups by name.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % varargin : cell array of strings
            %    The group name(s).

            jsondata = struct();
            jsondata.command = 'leave';
            jsondata.name = varargin;

            sendmsg(obj, jsondata, uint8.empty);

            [jsondata, ~] = recvmsg(obj);

            if jsondata.status < 0
                error(jsondata.error);
            end
        end

        function [] = send_var(obj, name, varargin)
            % Alias for send

            send(obj, name, varargin{:});
        end

        function [] = send(obj, name, varargin)
            % Send a "send" command to the server
            %
            % Sends one or more variables from the base workspace to all
            % clients in a specified group.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % name : string
            %    the group name.
            %
            % varargin : cell array of string
            %    The variable name(s) in the workspace.

            v = struct();

            for i = 1:length(varargin)
                v.(varargin{i}) =  evalin('caller', varargin{i});
            end

            send_r(obj, name, v);
        end

        function [] = send_r(obj, name, varargin)
            % Send a "send" command to the server (workspace-safe)
            %
            % Sends one or more variables passed either as a struct or as
            % key-value pairs to all clients in a specified group.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % name : string
            %    the group name.
            %
            % varargin : cell array
            %    One of the following:
            %
            %    * A single argument, a struct whose field names are variable
            %      names and values are the variables themselves
            %    * Two or more arguments alternating between strings specifying
            %      the variable names and arbitrary values representing the
            %      variables (similar to the struct constructor with one or
            %      more initial fields)

            if length(varargin) > 1
                v = struct(varargin{:});
            else
                v = varargin{1};
            end

            k = fieldnames(v);
            serialization = obj.serialization;

            for i = 1:16:length(k)
                n = 0;

                for j = i:min(i + 16, length(k))
                    jsondata = struct();
                    jsondata.command = 'send';
                    jsondata.name = name;
                    jsondata.varname = k{j};
                    jsondata.serialization = obj.serialization;

                    switch obj.serialization
                    case 'matlab'
                        bindata = getByteStreamFromArray(v.(k{j}));

                    case 'dimeb'
                        bindata = dimebdumps(v.(k{j}));
                    end

                    sendmsg(obj, jsondata, bindata);

                    n = n + 1;
                end

                for j = 1:n
                    [jsondata, bindata] = recvmsg(obj);

                    if jsondata.status < 0
                        error(jsondata.error);
                    end
                end


                if ~strcmp(serialization, obj.serialization)
                    send_r(obj, name, v);
                    return;
                end
            end
        end

        function [] = broadcast(obj, varargin)
            % Send a "broadcast" command to the server
            %
            % Sends one or more variables from the base workspace to all other
            % clients.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % varargin : cell array of string
            %    The variable name(s) in the workspace.

            v = struct();

            for i = 1:length(varargin)
                v.(varargin{i}) =  evalin('caller', varargin{i});
            end

            broadcast_r(obj, v);
        end

        function [] = broadcast_r(obj, varargin)
            % Send a "broadcast" command to the server (workspace-safe)
            %
            % Sends one or more variables passed either as a struct or as
            % key-value pairs to all other clients.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % varargin : cell array
            %    One of the following:
            %
            %    * A single argument, a struct whose field names are variable
            %      names and values are the variables themselves
            %    * Two or more arguments alternating between strings specifying
            %      the variable names and arbitrary values representing the
            %      variables (similar to the struct constructor with one or
            %      more initial fields)

            if length(varargin) > 1
                v = struct(varargin{:});
            else
                v = varargin{1};
            end

            k = fieldnames(v);
            serialization = obj.serialization;

            for i = 1:16:length(k)
                n = 0;

                for j = i:min(i + 16, length(k))
                    jsondata = struct();
                    jsondata.command = 'broadcast';
                    jsondata.varname = k{j};
                    jsondata.serialization = obj.serialization;

                    switch obj.serialization
                    case 'matlab'
                        bindata = getByteStreamFromArray(v.(k{j}));

                    case 'dimeb'
                        bindata = dimebdumps(v.(k{j}));
                    end

                    sendmsg(obj, jsondata, bindata);

                    n = n + 1;
                end

                for j = 1:n
                    [jsondata, bindata] = recvmsg(obj);

                    if jsondata.status < 0
                        error(jsondata.error);
                    end
                end

                if ~strcmp(serialization, obj.serialization)
                    broadcast_r(obj, v);
                    return;
                end
            end
        end

        function [] = sync(obj, n)
            % Send a "sync" command to the server
            %
            % Tell the server to start sending this client the variables sent
            % to this client by other clients.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % n : scalar
            %    Number of variables to retrieve from the server. Retrieves all
            %    variables if left unspecified

            if nargin < 2
                n = -1;
            end

            v = sync_r(obj, n);
            k = fieldnames(v);

            for i = 1:length(k)
                assignin('caller', k{i}, v.(k{i}));
            end
        end

        function [v] = sync_r(obj, n)
            % Send a "sync" command to the server (workspace safe)
            %
            % Tell the server to start sending this client the variables sent
            % to this client by other clients. Does not access the workspace.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % n : scalar
            %    Number of variables to retrieve from the server. Retrieves all
            %    variables if left unspecified
            %
            % Returns
            % -------
            % struct
            %     A struct of the retrieved variable names and their
            %     corresponding values.

            if nargin < 2
                n = -1;
            end

            jsondata = struct();
            jsondata.command = 'sync';
            jsondata.n = n;

            sendmsg(obj, jsondata, uint8.empty);

            v = struct();
            m = n;

            while true
                [jsondata, bindata] = recvmsg(obj);

                if ~isfield(jsondata, 'varname')
                    break;
                end

                switch jsondata.serialization
                case 'matlab'
                    x = getArrayFromByteStream(bindata);

                case 'dimeb'
                    x = dimebloads(bindata);

                otherwise
                    m = m - 1;
                    continue
                end

                v.(jsondata.varname) = x;
            end

            if n > 0 && m < n
                v_new = sync_r(obj, n - m);
                k = fieldnames(v_new);

                for i = 1:length(fields)
                    v.(k{i}) = v_new.(k{i});
                end
            end
        end

        function [n] = wait(obj)
            % Send a "wait" command to the server
            %
            % Tell the server to send a message once at least one message has
            % been received for the client. This method blocks the current
            % thread of execution until the message is received.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.

            jsondata = struct();
            jsondata.command = 'wait';

            sendmsg(obj, jsondata, uint8.empty);

            [jsondata, ~] = recvmsg(obj);

            if jsondata.status < 0
                error(jsondata.error);
            end

            n = jsondata.n;
        end

        function [names] = get_devices(obj)
            % Alias for devices

            names = devices(obj);
        end

        function [names] = devices(obj)
            % send Send a "devices" command to the server
            %
            % Tell the server to send this client a list of all the named,
            % nonempty groups connected to the server.
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % Returns
            % -------
            % cell array of string
            %     A list of all groups connected to the DiME server.

            jsondata = struct();
            jsondata.command = 'devices';

            sendmsg(obj, jsondata, uint8.empty);

            [jsondata, ~] = recvmsg(obj);

            if jsondata.status < 0
                error(jsondata.error);
            else
                names = jsondata.devices;

                if isequal(names, [])
                    names = {};
                end
            end
        end

        function [] = sendmsg(obj, json, bindata)
            % Send a raw DiME message over the socket
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % jsondata : cell array or struct
            %     JSON portion of the message to send
            %
            % bindata : uint8
            %     Binary portion of the message to send

            [~, ~, endianness] = computer;

            json = uint8(jsonencode(json));

            json_len = uint32(length(json));
            bindata_len = uint32(length(bindata));

            % Convert to network (big) endianness
            if endianness == 'L'
                json_len = swapbytes(json_len);
                bindata_len = swapbytes(bindata_len);
            end

            header = [uint8('DiME') typecast(json_len, 'uint8') typecast(bindata_len, 'uint8')];

            obj.send_ll([header json bindata]);

            %disp(['-> ' char(json)]);
        end

        function [json, bindata] = recvmsg(obj)
            % Receive a raw DiME message over the socket
            %
            % Parameters
            % ----------
            % obj : dime
            %     The dime instance.
            %
            % Returns
            % -------
            % jsondata : cell array or struct
            %     JSON portion of the message received
            %
            % bindata : uint8
            %     Binary portion of the message received

            [~, ~, endianness] = computer;

            header = obj.recv_ll(12);

            if header(1:4) ~= uint8('DiME')
                error('Invalid DiME message');
            end

            json_len = typecast(header(5:8), 'uint32');
            bindata_len = typecast(header(9:12), 'uint32');

            % Convert from network (big) endianness
            if endianness == 'L'
                json_len = swapbytes(json_len);
                bindata_len = swapbytes(bindata_len);
            end

            % Faster to get both in one syscall
            msg = obj.recv_ll(json_len + bindata_len);

            json = jsondecode(char(msg(1:json_len)));
            bindata = msg((json_len + 1):end);

            if isfield(json, 'status') && json.status > 0 && isfield(json, 'meta') && json.meta
                metamsg(obj, json);
                [json, bindata] = recvmsg(obj);
            end

            %disp(['<- ' char(msg(1:json_len))]);
        end

        function [] = metamsg(obj, json)
            if isfield(json, 'serialization')
                obj.serialization = json.serialization;
            else % No other commands supported yet
                error('Received unknown meta-status from server');
            end

        end
    end
end
